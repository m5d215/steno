@preconcurrency import AVFoundation
import Foundation
import os

/// マイク入力を AVAudioEngine で取得し、AVAudioPCMBuffer で渡す。
///
/// iOS はデバイスが実質 1 本で、経路(内蔵/イヤホン/BT)は AVAudioSession が扱う。
/// steno(macOS)は特定デバイス固定のため AVCaptureSession だったが、iOS では inputNode tap が素直。
///
/// 常時録音のキモ:
/// - category `.record` の AVAudioSession を activate し、`UIBackgroundModes: audio` と併せて
///   バックグラウンドでも録り続ける。
/// - **interruption / route change で wedge する** のを 2 系統で復帰させる:
///   1. `interruptionNotification`(電話・他アプリが audio を奪う)の .ended で再開。
///   2. liveness watchdog: 一定秒バッファが来なければ engine を作り直す(経路変化後の取りこぼし保険)。
/// - tap の format は inputNode の実フォーマットから取る(固定しない。steno の教訓)。
final class MicCapturer: @unchecked Sendable {
    private let onBuffer: @Sendable (AVAudioPCMBuffer) -> Void
    private var engine = AVAudioEngine()

    // engine の生成/差し替えは全てこのキュー上でだけ行う(watchdog と通知ハンドラの競合を直列化)。
    private let engineQueue = DispatchQueue(label: "com.m5d215.steno-mobile.mic.engine")

    private let lastBufferAt = OSAllocatedUnfairLock(initialState: Date.distantPast)
    private var watchdogTask: Task<Void, Never>?
    private var observers: [NSObjectProtocol] = []
    private let staleThreshold: TimeInterval = 8

    init(onBuffer: @escaping @Sendable (AVAudioPCMBuffer) -> Void) {
        self.onBuffer = onBuffer
    }

    func start() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.record, mode: .default, options: [])
        try session.setActive(true)
        try startEngine()
        registerObservers()
        startWatchdog()
        ilog("mic started")
    }

    func stop() {
        watchdogTask?.cancel()
        watchdogTask = nil
        for o in observers { NotificationCenter.default.removeObserver(o) }
        observers.removeAll()
        engineQueue.sync { stopEngine() }
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
        ilog("mic stopped")
    }

    // MARK: - engine

    private func startEngine() throws {
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)  // 実 hardware format。固定しない。
        input.removeTap(onBus: 0)
        let onBuffer = self.onBuffer
        let lastBufferAt = self.lastBufferAt
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { buffer, _ in
            lastBufferAt.withLock { $0 = Date() }
            onBuffer(buffer)
        }
        engine.prepare()
        try engine.start()
        lastBufferAt.withLock { $0 = Date() }
    }

    private func stopEngine() {
        engine.inputNode.removeTap(onBus: 0)
        if engine.isRunning { engine.stop() }
    }

    /// engine を作り直して再開(wedge からの復帰)。engineQueue 上で直列に実行する。
    private func restart(reason: String) {
        engineQueue.async { [weak self] in
            guard let self else { return }
            ilog("mic restart: \(reason)")
            self.stopEngine()
            self.engine = AVAudioEngine()
            do {
                try AVAudioSession.sharedInstance().setActive(true)
                try self.startEngine()
            } catch {
                ilog("mic restart failed: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - interruption / route change

    private func registerObservers() {
        let nc = NotificationCenter.default
        observers.append(
            nc.addObserver(
                forName: AVAudioSession.interruptionNotification, object: nil, queue: nil
            ) { [weak self] note in
                self?.handleInterruption(note)
            })
        observers.append(
            nc.addObserver(
                forName: AVAudioSession.routeChangeNotification, object: nil, queue: nil
            ) { [weak self] note in
                self?.handleRouteChange(note)
            })
    }

    private func handleInterruption(_ note: Notification) {
        guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
            let type = AVAudioSession.InterruptionType(rawValue: raw)
        else { return }
        switch type {
        case .began:
            ilog("mic interruption began")
        case .ended:
            let opts: AVAudioSession.InterruptionOptions
            if let o = note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt {
                opts = AVAudioSession.InterruptionOptions(rawValue: o)
            } else {
                opts = []
            }
            if opts.contains(.shouldResume) {
                restart(reason: "interruption ended")
            }
        @unknown default:
            break
        }
    }

    private func handleRouteChange(_ note: Notification) {
        guard let raw = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
            let reason = AVAudioSession.RouteChangeReason(rawValue: raw)
        else { return }
        switch reason {
        case .oldDeviceUnavailable, .newDeviceAvailable, .override, .categoryChange:
            restart(reason: "route change (\(reason.rawValue))")
        default:
            break
        }
    }

    // MARK: - liveness watchdog

    private func startWatchdog() {
        watchdogTask?.cancel()
        watchdogTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(4))
                guard let self else { break }
                let idle = Date().timeIntervalSince(self.lastBufferAt.withLock { $0 })
                if idle > self.staleThreshold {
                    self.restart(reason: "watchdog: no samples \(Int(idle))s")
                }
            }
        }
    }
}
