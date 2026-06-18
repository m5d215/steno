@preconcurrency import AVFoundation
import AudioToolbox
import CoreAudio
import Foundation
import os

// MARK: - Core Audio property helpers (file-private)

private func getProp<T>(
    _ obj: AudioObjectID, _ selector: AudioObjectPropertySelector,
    _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal, initial: T
) -> T? {
    var addr = AudioObjectPropertyAddress(
        mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    var value = initial
    var size = UInt32(MemoryLayout<T>.size)
    let st = withUnsafeMutablePointer(to: &value) {
        AudioObjectGetPropertyData(obj, &addr, 0, nil, &size, $0)
    }
    return st == noErr ? value : nil
}

private func defaultOutputDevice() -> AudioObjectID? {
    let id = getProp(
        AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice,
        initial: AudioObjectID(kAudioObjectUnknown))
    return (id == nil || id == kAudioObjectUnknown) ? nil : id
}

private func deviceUID(_ id: AudioObjectID) -> String? {
    (getProp(id, kAudioDevicePropertyDeviceUID, initial: "" as CFString) as String?)
}

private func deviceName(_ id: AudioObjectID) -> String {
    (getProp(id, kAudioObjectPropertyName, initial: "" as CFString) as String?) ?? "?"
}

private func tapASBD(_ tapID: AudioObjectID) -> AudioStreamBasicDescription? {
    var addr = AudioObjectPropertyAddress(
        mSelector: kAudioTapPropertyFormat, mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)
    var asbd = AudioStreamBasicDescription()
    var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
    let st = withUnsafeMutablePointer(to: &asbd) {
        AudioObjectGetPropertyData(tapID, &addr, 0, nil, &size, $0)
    }
    return st == noErr ? asbd : nil
}

/// system 音声(全プロセスの出力)を Core Audio process tap で取り、AVAudioPCMBuffer で渡す。
///
/// ScreenCaptureKit は使わない: SCK は replayd hang / 経路変化で無音化し、watchdog 再起動でも
/// 戻らないことがある。tap は audio 専用で video pipeline も持たず、device に依存した死に方を
/// しないため安定し、省電力。
///
/// liveness は「frames が来ているか」で見る。tap は device が動いている限り無音でも
/// IOProc を継続的に叩くので、一定時間バッファが来ない = 本当に死んでいる。死を検知したら
/// tap と aggregate device を**両方**破棄して作り直す(片方だけの restart は不確実)。
/// 既定出力デバイスの変更にも追従して作り直す。
///
/// 並行性: ライフサイクル(setup/teardown/recreate)は controlQueue に直列化する。IOProc は
/// 専用の ioQueue で叩かれる。teardown 時の AudioDeviceStop は controlQueue から呼ぶので
/// ioQueue の IOProc 完了を待てる(同一 queue ではないのでデッドロックしない)。recreate の
/// 起動は常に controlQueue.async なので、controlQueue 上の listener から呼んでも安全。
final class AudioTapCapturer: @unchecked Sendable {
    private let onBuffer: @Sendable (AVAudioPCMBuffer) -> Void

    // tap 対象の出力デバイス名。UI 側が main の timer で pull する(actor 跨ぎの更新を避ける)。
    private let deviceNameLock = OSAllocatedUnfairLock(initialState: "—")
    var currentDeviceName: String { deviceNameLock.withLock { $0 } }

    // ライフサイクル状態(controlQueue 上でのみ触る)
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private var deviceListenerInstalled = false

    // IOProc(ioQueue) と controlQueue の双方から触る共有状態はロックで保護
    private let format = OSAllocatedUnfairLock<AVAudioFormat?>(initialState: nil)
    private let lastBufferAt = OSAllocatedUnfairLock(initialState: Date.distantPast)
    private let deviceRate = OSAllocatedUnfairLock(initialState: Double(0))  // tap を作った時の出力デバイスの nominal rate
    private let outDevice = OSAllocatedUnfairLock(initialState: AudioObjectID(kAudioObjectUnknown))  // tap が乗る出力デバイス

    // 現出力デバイスの sample rate 変化リスナー(BT プロファイル切り替え等を捕まえる)。controlQueue 限定。
    private var formatListenerBlock: AudioObjectPropertyListenerBlock?
    private var formatListenerDevice = AudioObjectID(kAudioObjectUnknown)

    private let controlQueue = DispatchQueue(label: "com.m5d215.steno.audiotap.control")
    private let ioQueue = DispatchQueue(label: "com.m5d215.steno.audiotap.io")
    private var watchdogTask: Task<Void, Never>?

    private let staleThreshold: TimeInterval = 10  // この秒数 frames が来なければ tap 死とみなす

    init(onBuffer: @escaping @Sendable (AVAudioPCMBuffer) -> Void) {
        self.onBuffer = onBuffer
    }

    func start() throws {
        try controlQueue.sync { try setupTap() }
        installDefaultDeviceListener()
        startWatchdog()
    }

    func stop() {
        watchdogTask?.cancel()
        watchdogTask = nil
        controlQueue.sync { teardownTap() }
    }

    /// tap/aggregate を作り直す(死亡検知・デバイス変更時)。常に async で controlQueue に投げるので
    /// controlQueue 上の listener から呼んでも再入デッドロックしない。
    private func requestRecreate(reason: String) {
        controlQueue.async { [weak self] in
            guard let self else { return }
            ilog("recreating system tap: \(reason)")
            self.teardownTap()
            do {
                try self.setupTap()
            } catch {
                ilog("system tap recreate failed: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - tap/aggregate 構築・破棄 (controlQueue 上で呼ぶ)

    private func setupTap() throws {
        guard let output = defaultOutputDevice(), let outUID = deviceUID(output) else {
            throw NSError(
                domain: "AudioTapCapturer", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "no default output device"])
        }

        // 全プロセスの出力を mono global tap で。muteBehavior=.unmuted で再生はそのまま鳴らす。
        let tapDesc = CATapDescription(monoGlobalTapButExcludeProcesses: [])
        tapDesc.name = "steno-system-tap"
        tapDesc.isPrivate = true
        tapDesc.muteBehavior = .unmuted

        var tap = AudioObjectID(kAudioObjectUnknown)
        let tapStatus = AudioHardwareCreateProcessTap(tapDesc, &tap)
        guard tapStatus == noErr, tap != kAudioObjectUnknown else {
            throw NSError(
                domain: "AudioTapCapturer", code: 2,
                userInfo: [NSLocalizedDescriptionKey: "AudioHardwareCreateProcessTap failed: \(tapStatus)"])
        }
        tapID = tap

        guard var asbd = tapASBD(tap), let fmt = AVAudioFormat(streamDescription: &asbd) else {
            teardownTap()
            throw NSError(
                domain: "AudioTapCapturer", code: 3,
                userInfo: [NSLocalizedDescriptionKey: "tap format unavailable"])
        }
        format.withLock { $0 = fmt }

        let tapUID = (getProp(tap, kAudioTapPropertyUID, initial: "" as CFString) as String?) ?? ""
        let aggDescription: [String: Any] = [
            kAudioAggregateDeviceNameKey: "steno-agg",
            // UID はプロセスごとに一意にする。固定だと steno を 2 つ起動(常用版 + 開発版)したとき
            // 同 UID の aggregate device 生成がぶつかり 2 個目の capture が立たない。
            kAudioAggregateDeviceUIDKey: "com.m5d215.steno.agg.\(ProcessInfo.processInfo.processIdentifier)",
            kAudioAggregateDeviceMainSubDeviceKey: outUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outUID]],
            kAudioAggregateDeviceTapListKey: [
                [kAudioSubTapDriftCompensationKey: true, kAudioSubTapUIDKey: tapUID]
            ],
        ]
        var agg = AudioObjectID(kAudioObjectUnknown)
        let aggStatus = AudioHardwareCreateAggregateDevice(aggDescription as CFDictionary, &agg)
        guard aggStatus == noErr, agg != kAudioObjectUnknown else {
            teardownTap()
            throw NSError(
                domain: "AudioTapCapturer", code: 4,
                userInfo: [NSLocalizedDescriptionKey: "AudioHardwareCreateAggregateDevice failed: \(aggStatus)"])
        }
        aggID = agg

        var proc: AudioDeviceIOProcID?
        let ioStatus = AudioDeviceCreateIOProcIDWithBlock(&proc, agg, ioQueue) {
            [weak self] (_, inInputData, _, _, _) in
            self?.handleIO(inInputData)
        }
        guard ioStatus == noErr, let proc else {
            teardownTap()
            throw NSError(
                domain: "AudioTapCapturer", code: 5,
                userInfo: [NSLocalizedDescriptionKey: "AudioDeviceCreateIOProcIDWithBlock failed: \(ioStatus)"])
        }
        ioProcID = proc

        let startStatus = AudioDeviceStart(agg, proc)
        guard startStatus == noErr else {
            teardownTap()
            throw NSError(
                domain: "AudioTapCapturer", code: 6,
                userInfo: [NSLocalizedDescriptionKey: "AudioDeviceStart failed: \(startStatus)"])
        }

        let now = Date()
        lastBufferAt.withLock { $0 = now }
        // tap format(fmt.sampleRate)ではなく**デバイスの nominal rate** を覚える。tap format は
        // デバイスのレートと別レイヤーで常に異なりうる(48000 tap on 44100 device は正常)。watchdog
        // が「デバイスのレートが変わったか」を同レイヤーで比較できるよう、デバイス側の値を記録する。
        let devRate = getProp(output, kAudioDevicePropertyNominalSampleRate, initial: Double(0)) ?? 0
        deviceRate.withLock { $0 = devRate }
        outDevice.withLock { $0 = output }
        installFormatListener(on: output)
        let outName = deviceName(output)
        ilog("system tap started (\(outName), \(Int(fmt.sampleRate))Hz \(fmt.channelCount)ch)")
        deviceNameLock.withLock { $0 = outName }
    }

    /// 現出力デバイスの sample rate 変化を監視する(controlQueue 上で叩かれる)。BT のプロファイル
    /// 切り替え(A2DP ⇄ HFP)は**デバイス ID を変えずに**フォーマットだけ変えるので、既定デバイス
    /// 変更リスナーでは捕まらない。これを取り逃すと tap が無音バッファだけ流し続けるので、ここと
    /// watchdog の device-rate reconciliation の二段で必ず拾う。
    private func installFormatListener(on device: AudioObjectID) {
        removeFormatListener()
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.requestRecreate(reason: "output device format changed")
        }
        let st = AudioObjectAddPropertyListenerBlock(device, &addr, controlQueue, block)
        if st == noErr {
            formatListenerBlock = block
            formatListenerDevice = device
        }
    }

    private func removeFormatListener() {
        guard let block = formatListenerBlock, formatListenerDevice != kAudioObjectUnknown else {
            return
        }
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        AudioObjectRemovePropertyListenerBlock(formatListenerDevice, &addr, controlQueue, block)
        formatListenerBlock = nil
        formatListenerDevice = kAudioObjectUnknown
    }

    private func teardownTap() {
        removeFormatListener()
        if aggID != kAudioObjectUnknown, let proc = ioProcID {
            AudioDeviceStop(aggID, proc)  // ioQueue の IOProc 完了を待つ(controlQueue から呼ぶので安全)
            AudioDeviceDestroyIOProcID(aggID, proc)
        }
        ioProcID = nil
        if aggID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggID)
            aggID = kAudioObjectUnknown
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = kAudioObjectUnknown
        }
        format.withLock { $0 = nil }
    }

    // MARK: - IOProc (ioQueue)

    private func handleIO(_ inInputData: UnsafePointer<AudioBufferList>) {
        guard let fmt = format.withLock({ $0 }) else { return }
        let inAbl = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inInputData))
        let bytesPerFrame = fmt.streamDescription.pointee.mBytesPerFrame
        guard bytesPerFrame > 0, let first = inAbl.first, first.mDataByteSize > 0 else { return }
        let frames = AVAudioFrameCount(first.mDataByteSize / bytesPerFrame)
        guard frames > 0, let pcm = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: frames) else {
            return
        }
        pcm.frameLength = frames

        let outAbl = UnsafeMutableAudioBufferListPointer(pcm.mutableAudioBufferList)
        for i in 0..<min(inAbl.count, outAbl.count) {
            guard let src = inAbl[i].mData, let dst = outAbl[i].mData else { continue }
            let n = Int(min(inAbl[i].mDataByteSize, outAbl[i].mDataByteSize))
            memcpy(dst, src, n)
        }

        lastBufferAt.withLock { $0 = Date() }
        onBuffer(pcm)
    }

    // MARK: - liveness watchdog

    private func startWatchdog() {
        watchdogTask?.cancel()
        watchdogTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                guard let self else { break }
                let now = Date()

                // (1) frames-stall: バッファ自体が来ない = tap が完全に死んでる
                let idle = now.timeIntervalSince(self.lastBufferAt.withLock { $0 })
                if idle > self.staleThreshold {
                    ilog("watchdog: no system audio for \(Int(idle))s, recreating tap")
                    self.requestRecreate(reason: "stale \(Int(idle))s")
                    continue
                }

                // (2) device-rate reconciliation: 出力デバイスの nominal rate が tap 作成時から変わった
                // = BT プロファイル切り替え等の実イベント。format listener が取りこぼしても 5 秒以内に拾う
                // backstop。比較は「デバイスの今 vs 作成時」(同レイヤー)なので、recreate 後に基準が更新
                // されて収束する(tap format と比べると常時ズレて永久ループになる — それが前版のバグ)。
                let dev = self.outDevice.withLock { $0 }
                let createdRate = self.deviceRate.withLock { $0 }
                if dev != kAudioObjectUnknown, createdRate > 0,
                    let live = getProp(dev, kAudioDevicePropertyNominalSampleRate, initial: Double(0)),
                    live > 0, abs(live - createdRate) > 1
                {
                    ilog("watchdog: output device rate changed \(Int(createdRate))→\(Int(live))Hz, recreating tap")
                    self.requestRecreate(reason: "device rate \(Int(createdRate))→\(Int(live))Hz")
                    continue
                }
            }
        }
    }

    // MARK: - 既定出力デバイス変更の追従

    private func installDefaultDeviceListener() {
        guard !deviceListenerInstalled else { return }
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        let status = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &addr, controlQueue
        ) { [weak self] (_, _) in
            self?.requestRecreate(reason: "default output device changed")
        }
        deviceListenerInstalled = status == noErr
    }
}
