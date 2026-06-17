@preconcurrency import AVFoundation
import CoreMedia
import Foundation
import os

/// 自分のマイク入力を **AVCaptureSession** で取得し、AVAudioPCMBuffer で渡す。
///
/// AVAudioEngine ではなく AVCaptureSession を使う: AVAudioEngine は設計上システム既定入力を追い、
/// AUHAL の CurrentDevice 上書きは start 時に巻き戻る(プロパティは立つが実データ経路は既定のまま)
/// ため、「既定が変わっても指定マイクで録る」が実現できない。AVCaptureSession は
/// AVCaptureDevice(uniqueID:) で**特定デバイスに本当にバインド**し、システム既定を追わない。
/// これが Apple 推奨の特定デバイス録音の正道。
///
/// preferredUID(=AVCaptureDevice.uniqueID)を指定すればそのデバイス固定。nil なら既定。
/// liveness watchdog も持つ: 一定秒 sample が来なければ session を作り直す(経路変化後の wedge 復帰)。
final class MicCapturer: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable
{
    private let onBuffer: @Sendable (AVAudioPCMBuffer) -> Void
    private var session: AVCaptureSession?
    private var preferredUID: String?

    private let sessionQueue = DispatchQueue(label: "com.m5d215.steno.mic.session")
    private let dataQueue = DispatchQueue(label: "com.m5d215.steno.mic.data")

    private let deviceNameLock = OSAllocatedUnfairLock(initialState: "—")
    var currentDeviceName: String { deviceNameLock.withLock { $0 } }

    private let lastBufferAt = OSAllocatedUnfairLock(initialState: Date.distantPast)
    private var watchdogTask: Task<Void, Never>?
    private let staleThreshold: TimeInterval = 8

    init(onBuffer: @escaping @Sendable (AVAudioPCMBuffer) -> Void) {
        self.onBuffer = onBuffer
        super.init()
    }

    func start(preferredUID: String?) {
        sessionQueue.async {
            self.preferredUID = preferredUID
            self.configureAndStart(reason: "start")
        }
        startWatchdog()
    }

    func stop() {
        watchdogTask?.cancel()
        watchdogTask = nil
        sessionQueue.async {
            self.session?.stopRunning()
            self.session = nil
        }
    }

    /// picker から別デバイスへ切り替える。
    func switchDevice(preferredUID: String?) {
        sessionQueue.async {
            self.preferredUID = preferredUID
            self.configureAndStart(reason: "switch device")
        }
    }

    // MARK: - session 構築 (sessionQueue 上で実行)

    private func pickDevice() -> AVCaptureDevice? {
        if let uid = preferredUID, let d = AVCaptureDevice(uniqueID: uid) { return d }
        return AVCaptureDevice.default(for: .audio)
    }

    private func configureAndStart(reason: String) {
        session?.stopRunning()
        session = nil

        guard let device = pickDevice() else {
            ilog("mic: no capture device available")
            return
        }
        guard let input = try? AVCaptureDeviceInput(device: device) else {
            ilog("mic: cannot create input for \(device.localizedName)")
            return
        }

        let s = AVCaptureSession()
        s.beginConfiguration()
        guard s.canAddInput(input) else {
            ilog("mic: cannot add input")
            s.commitConfiguration()
            return
        }
        s.addInput(input)
        let output = AVCaptureAudioDataOutput()
        output.setSampleBufferDelegate(self, queue: dataQueue)
        guard s.canAddOutput(output) else {
            ilog("mic: cannot add output")
            s.commitConfiguration()
            return
        }
        s.addOutput(output)
        s.commitConfiguration()
        s.startRunning()

        session = s
        lastBufferAt.withLock { $0 = Date() }
        let name = device.localizedName
        deviceNameLock.withLock { $0 = name }
        ilog("mic started (\(name)) via AVCaptureSession [\(reason)]")
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
                    self.sessionQueue.async {
                        guard self.session != nil else { return }
                        self.configureAndStart(reason: "watchdog: no samples \(Int(idle))s")
                    }
                }
            }
        }
    }

    // MARK: - AVCaptureAudioDataOutputSampleBufferDelegate (dataQueue)

    func captureOutput(
        _ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard let pcm = Self.pcmBuffer(from: sampleBuffer) else { return }
        lastBufferAt.withLock { $0 = Date() }
        onBuffer(pcm)
    }

    /// CMSampleBuffer(音声) → AVAudioPCMBuffer。フォーマットは sample buffer から取る。
    static func pcmBuffer(from sb: CMSampleBuffer) -> AVAudioPCMBuffer? {
        guard let fd = CMSampleBufferGetFormatDescription(sb),
            var asbd = CMAudioFormatDescriptionGetStreamBasicDescription(fd)?.pointee,
            let fmt = AVAudioFormat(streamDescription: &asbd)
        else { return nil }
        let frames = AVAudioFrameCount(CMSampleBufferGetNumSamples(sb))
        guard frames > 0, let pcm = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: frames)
        else { return nil }
        pcm.frameLength = frames
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sb, at: 0, frameCount: Int32(frames), into: pcm.mutableAudioBufferList)
        guard status == noErr else { return nil }
        return pcm
    }
}
