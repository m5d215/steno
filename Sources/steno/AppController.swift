import AVFoundation
import AppKit
import Foundation
import Speech
import os

/// UI 表示用の 1 行。jsonl とは別に、確定発話を in-process でそのまま UI へ流すための型。
struct TranscriptLine: Identifiable {
    let id = UUID()
    let time: Date
    let source: String
    let app: String?
    let text: String
}

/// 録音パイプライン(capturer/transcriber/writer)を保持し start/stop を仲介する。
/// system 音声は Core Audio tap、mic は AVCaptureSession。話者の区別は source(system=相手 /
/// mic=自分)だけで取る。話者分離モデルは持たない: 精度の低い話者ラベルは後段の LLM 要約には
/// むしろ害で、高精度な source 区別で十分だから。
@MainActor
final class AppController: ObservableObject {
    @Published private(set) var isRecording = false
    @Published private(set) var ready = false
    @Published private(set) var statusLine = "起動中…"

    /// UI に出す確定発話(直近 maxLines 行)。writer への append と同じ record を流す。
    @Published private(set) var lines: [TranscriptLine] = []
    private let maxLines = 1000

    func display(_ r: TranscriptRecord) {
        lines.append(TranscriptLine(time: r.start, source: r.source, app: r.app, text: r.text))
        if lines.count > maxLines { lines.removeFirst(lines.count - maxLines) }
    }

    /// 現在 capture に使っているデバイス名(UI 表示用)。capturer の onDevice から更新される。
    @Published private(set) var systemDeviceName = "—"
    @Published private(set) var micDeviceName = "—"

    /// 入力デバイス一覧(mic picker 用)。デバイス抜き差しで更新。
    @Published private(set) var inputDevices: [AudioInputDevice] = []

    /// 選択中の mic デバイス(UID, nil=システム既定)。UID で永続化(ID は抜き差しで変わるため)。
    @Published var selectedMicUID: String? = {
        let s = UserDefaults.standard.string(forKey: "micDeviceUID") ?? ""
        return s.isEmpty ? nil : s
    }() {
        didSet {
            UserDefaults.standard.set(selectedMicUID ?? "", forKey: "micDeviceUID")
            // SwiftUI 更新サイクル中に capture session の重い stop/start を直接走らせると再入で危険。
            // 次の main runloop に逃がす。録音中だけ即切り替え、停止中は次回 start で反映。
            if isRecording {
                let uid = selectedMicUID
                Task { @MainActor [weak self] in self?.micCapturer?.switchDevice(preferredUID: uid) }
            }
        }
    }

    private var writer: TranscriptWriter?
    private var systemTranscriber: Transcriber?
    private var micTranscriber: Transcriber?
    private var systemCapturer: AudioTapCapturer?
    private var micCapturer: MicCapturer?
    private var recordingSince: Date?

    /// App Nap 抑止のための activity assertion(アプリ生存中ずっと握る)。
    /// UI 形態に依らず明示的に assertion を握ることで、窓を隠しても SpeechAnalyzer が wedge しない。
    private var activityToken: NSObjectProtocol?

    /// [spike] finalize(through:) の force-cut 検証用の周期タスク(STENO_FINALIZE_SPIKE=秒 で有効)。
    private var finalizeSpikeTask: Task<Void, Never>?

    /// [spike] system 音声の話者ターン境界検出器(STENO_DIAR=1 で有効)。境界で発話を切る。
    private var segmenter: SpeakerSegmenter?

    init() {
        activityToken = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiatedAllowingIdleSystemSleep],
            reason: "continuous on-device transcription")
        Task { await bootstrap() }
    }

    private func bootstrap() async {
        guard !ready else { return }
        let baseDir = Self.resolveTranscriptDir()
        ilog("transcript dir: \(baseDir.path)")

        guard await Self.requestSpeechAuth() else {
            statusLine = "音声認識の許可が必要です"
            ilog("speech recognition authorization denied")
            return
        }

        let writer = TranscriptWriter(baseDir: baseDir)
        let locale = Locale(
            components: .init(languageCode: .japanese, script: nil, languageRegion: .japan))
        let vocab = Self.loadVocabulary()
        ilog("vocabulary: \(vocab.count) terms")

        // source ごとに別エンジン。確定発話をそのまま jsonl + UI へ。
        // system だけ app を付ける(= 確定時に出力中だったアプリ。global tap は出元情報を持たない
        // ので heuristic に点読みする)。mic は自分のマイクで app が無意味なので付けない。
        let systemTranscriber = Transcriber(
            locale: locale, label: "system", contextualStrings: vocab
        ) { [weak self, writer] text, when in
            let app = OutputProcesses.currentOutputAppName()
            Task {
                let record = TranscriptRecord(start: when, source: "system", app: app, text: text)
                await writer.append(record)
                await self?.display(record)
            }
        }
        let micTranscriber = Transcriber(
            locale: locale, label: "mic", contextualStrings: vocab
        ) { [weak self, writer] text, when in
            Task {
                let record = TranscriptRecord(start: when, source: "mic", app: nil, text: text)
                await writer.append(record)
                await self?.display(record)
            }
        }

        do {
            try await systemTranscriber.start()
            try await micTranscriber.start()
            ilog("transcribers started (locale: \(locale.identifier))")
        } catch {
            statusLine = "文字起こしエンジン起動失敗"
            ilog("transcriber start failed: \(error.localizedDescription)")
            return
        }

        // [spike] finalize(through:) の挙動検証。STENO_FINALIZE_SPIKE=<秒> で system/mic 両 transcriber を
        // 周期的に強制 final 確定し、長い連続発話の途中で final が切れて後続も拾い続けるか
        // (= 話者境界 force-cut の土台が成立するか)を実測する。mic も対象なのでソロで長文を喋れば
        // 検証できる(通話音声を流す必要なし)。挙動は source 非依存。本番経路には影響しない。
        if let s = ProcessInfo.processInfo.environment["STENO_FINALIZE_SPIKE"],
            let interval = Double(s), interval > 0
        {
            finalizeSpikeTask = Task { [systemTranscriber, micTranscriber] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(interval))
                    ilog("[spike] force finalize(through:nil) on system+mic")
                    await systemTranscriber.finalizeThroughLatest()
                    await micTranscriber.finalizeThroughLatest()
                }
            }
            ilog("[spike] finalize spike enabled: every \(interval)s")
        }

        // [spike] STENO_DIAR=1 で system 音声に Streaming Sortformer を並走させ、話者ターン境界で
        // system transcriber を finalize(through:) して発話を切る。目的は区切りであって話者特定では
        // ない(ラベル精度は問わない)。object は先に作って capturer の closure に渡し、モデル読込
        // (start, 初回 download あり)は下で async に走らせる。読込前の feed は no-op。
        let segmenter: SpeakerSegmenter? =
            ProcessInfo.processInfo.environment["STENO_DIAR"] != nil
            ? SpeakerSegmenter { [systemTranscriber] in
                Task { await systemTranscriber.finalizeThroughLatest() }
            }
            : nil

        let systemCapturer = AudioTapCapturer { [systemTranscriber, segmenter] buf in
            systemTranscriber.stream(buf)
            segmenter?.feed(buf)
        }
        let micCapturer = MicCapturer { [micTranscriber] buf in
            micTranscriber.stream(buf)
        }

        self.writer = writer
        self.systemTranscriber = systemTranscriber
        self.micTranscriber = micTranscriber
        self.systemCapturer = systemCapturer
        self.micCapturer = micCapturer
        self.segmenter = segmenter
        inputDevices = AudioDevices.inputDevices()
        self.ready = true

        if let segmenter {
            ilog("[diar] enabled, loading models…")
            Task {
                do { try await segmenter.start() } catch {
                    ilog("[diar] start failed: \(error.localizedDescription)")
                }
            }
        }

        await start()
    }

    func toggle() {
        Task { isRecording ? await stop() : await start() }
    }

    func start() async {
        guard ready, !isRecording, let systemCapturer, let micCapturer else { return }
        do {
            try systemCapturer.start()
            micCapturer.start(preferredUID: selectedMicUID)
            isRecording = true
            recordingSince = Date()
            statusLine = ""  // 録音中はドット(オレンジ)とボタン(停止)で示す。冗長なテキストは出さない
            ilog("recording started")
        } catch {
            statusLine = "録音開始失敗: \(error.localizedDescription)"
            ilog("capture start failed: \(error.localizedDescription)")
        }
    }

    func stop() async {
        guard isRecording else { return }
        systemCapturer?.stop()
        micCapturer?.stop()
        isRecording = false
        recordingSince = nil
        statusLine = ""  // 停止中はドット(グレー)とボタン(開始)で示す
        ilog("recording stopped")
    }

    /// capture を丸ごと作り直す(アプリ再起動なしで wedge から復帰する手動リセット)。
    func reset() {
        Task {
            ilog("manual reset")
            await stop()
            await start()
        }
    }

    /// UI の main timer から定期的に呼ぶ。capturer の lock 値と入力デバイス一覧を取り込む。
    /// audio スレッドから @Published を直接触らない(executor 跨ぎの crash を避ける)ための pull 方式。
    func syncDeviceNames() {
        systemDeviceName = systemCapturer?.currentDeviceName ?? "—"
        micDeviceName = micCapturer?.currentDeviceName ?? "—"
        let devs = AudioDevices.inputDevices()
        if devs != inputDevices { inputDevices = devs }
    }

    // MARK: ユーティリティ

    nonisolated static func requestSpeechAuth() async -> Bool {
        await withCheckedContinuation { cont in
            SFSpeechRecognizer.requestAuthorization { status in
                cont.resume(returning: status == .authorized)
            }
        }
    }

    nonisolated static func configDir() -> URL {
        let env = ProcessInfo.processInfo.environment["STENO_DIR"]
        if let env, !env.isEmpty {
            return URL(fileURLWithPath: env, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appending(path: ".config/steno")
    }

    nonisolated static func resolveTranscriptDir() -> URL {
        let env = ProcessInfo.processInfo.environment["TRANSCRIPT_DIR"]
        if let env, !env.isEmpty {
            return URL(fileURLWithPath: env, isDirectory: true)
        }
        return configDir().appending(path: "transcripts")
    }

    /// 認識ヒント語彙。env STENO_VOCAB か、未指定なら configDir/vocabulary.txt。
    nonisolated static func loadVocabulary() -> [String] {
        let path = ProcessInfo.processInfo.environment["STENO_VOCAB"]
            ?? configDir().appending(path: "vocabulary.txt").path
        guard let content = try? String(contentsOfFile: path, encoding: .utf8) else { return [] }
        return content
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
    }
}
