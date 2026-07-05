import AVFoundation
import Foundation
import Observation
import Speech
import StenoCore

/// パイプラインの結線と UI 状態。mic → Transcriber → TranscriptStore(SSOT) → Shipper。
@MainActor
@Observable
final class AppModel {
    var isRunning = false
    var lines: [WireRecord] = []
    var pendingCount = 0
    var shipStatus = "待機中"
    var micStatus = "停止"

    private let store = TranscriptStore()
    private var transcriber: Transcriber?
    private var mic: MicCapturer?
    private var shipper: Shipper?
    private var pollTask: Task<Void, Never>?

    func start() async {
        guard !isRunning else { return }

        guard await requestPermissions() else {
            shipStatus = "マイク/音声認識の権限がありません"
            return
        }

        do {
            let store = self.store

            let t = Transcriber(locale: Locale(identifier: "ja-JP"), label: "mic") {
                [weak self] text, date in
                Task { @MainActor in await self?.handleFinal(text, date) }
            }
            try await t.start()
            self.transcriber = t

            let mic = MicCapturer { [weak t] buffer in t?.stream(buffer) }
            try mic.start()
            self.mic = mic
            self.micStatus = "録音中"

            let shipper = Shipper(store: store) { [weak self] status in
                self?.shipStatus = status
            }
            shipper.start()
            self.shipper = shipper

            startPolling()
            isRunning = true
            ilog("pipeline started")
        } catch {
            shipStatus = "起動失敗: \(error.localizedDescription)"
            ilog("start failed: \(error.localizedDescription)")
            await stop()
        }
    }

    func stop() async {
        mic?.stop()
        mic = nil
        shipper?.stop()
        shipper = nil
        await transcriber?.finish()
        transcriber = nil
        pollTask?.cancel()
        pollTask = nil
        micStatus = "停止"
        isRunning = false
        ilog("pipeline stopped")
    }

    private func handleFinal(_ text: String, _ date: Date) async {
        let rec = await store.append(text: text, at: date)
        lines.append(rec)
        if lines.count > 200 {
            lines.removeFirst(lines.count - 200)
        }
    }

    private func startPolling() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { break }
                self.pendingCount = await self.store.pendingCount
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    // nonisolated: 許可コールバックは TCC がバックグラウンドの XPC キューで呼ぶ。@MainActor を
    // 継承したクロージャだと Swift 6 の実行 executor 検査(_swift_task_checkIsolatedSwift)が
    // main 以外で trap する。self の状態は触らないので nonisolated にしてクロージャの隔離を外す。
    private nonisolated func requestPermissions() async -> Bool {
        let mic = await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
            AVAudioApplication.requestRecordPermission { granted in
                c.resume(returning: granted)
            }
        }
        let speech = await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
            SFSpeechRecognizer.requestAuthorization { status in
                c.resume(returning: status == .authorized)
            }
        }
        return mic && speech
    }
}
