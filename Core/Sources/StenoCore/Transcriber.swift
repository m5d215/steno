@preconcurrency import AVFoundation
import Foundation
import Speech

/// Apple SpeechAnalyzer + SpeechTranscriber によるオンデバイス文字起こし。
/// system 用・mic 用にインスタンスを分けて使う(source ごとに別エンジン)。
/// `stream(_:)` は capturer の audio queue から同期で呼ばれる前提。
///
/// App Nap は SpeechAnalyzer を wedge させる(音声は来るのに確定発話が出ない)。これは UI 形態
/// ではなく AppController 側の ProcessInfo.beginActivity で nap を明示的に抑止して対処する。
public final class Transcriber: @unchecked Sendable {
    private let locale: Locale
    private let label: String
    private let contextualStrings: [String]
    // (確定テキスト, 受信壁時計時刻)
    private let onFinal: @Sendable (String, Date) -> Void

    private var transcriber: SpeechTranscriber?
    private var analyzer: SpeechAnalyzer?
    private var inputBuilder: AsyncStream<AnalyzerInput>.Continuation?
    private var analyzerFormat: AVAudioFormat?
    private let converter = BufferConverter()
    private var recognizerTask: Task<Void, Never>?
    private var streamCount = 0

    public init(
        locale: Locale, label: String,
        contextualStrings: [String] = [],
        onFinal: @escaping @Sendable (String, Date) -> Void
    ) {
        self.locale = locale
        self.label = label
        self.contextualStrings = contextualStrings
        self.onFinal = onFinal
    }

    public func start() async throws {
        // volatile(中間仮説)は使わない(finals のみ消費)ので要求しない。話者ターン区切りは
        // Sortformer を別途並走させ finalize(through:) で切る方式なので、SpeechAnalyzer 側の
        // audioTimeRange(token 毎の経過秒区間)も要らない。
        let transcriber = SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [],
            attributeOptions: [])
        self.transcriber = transcriber

        let analyzer = SpeechAnalyzer(modules: [transcriber])
        self.analyzer = analyzer

        try await ensureModel(transcriber: transcriber, locale: locale)

        analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber])
        guard analyzerFormat != nil else {
            throw NSError(
                domain: "Transcriber", code: 2,
                userInfo: [NSLocalizedDescriptionKey: "no compatible audio format"])
        }

        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        self.inputBuilder = continuation

        let onFinal = self.onFinal
        let label = self.label
        recognizerTask = Task {
            do {
                for try await result in transcriber.results {
                    let text = String(result.text.characters)
                    dlog("[Transcriber:\(label)] final=\(result.isFinal) text=\"\(text)\"")
                    guard result.isFinal else { continue }
                    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    // 1 文字以下の確定は捨てる。長い発話の途中で早期に finalize される断片
                    // (「あ」「こ」等)で、UI も jsonl も汚すだけ。2 文字以上の発話のみ採用する。
                    guard trimmed.count >= 2 else { continue }
                    onFinal(trimmed, Date())
                }
            } catch {
                ilog("[\(label)] results error: \(error.localizedDescription)")
            }
        }

        if !contextualStrings.isEmpty {
            let ctx = AnalysisContext()
            ctx.contextualStrings[.general] = contextualStrings
            try await analyzer.setContext(ctx)
            ilog("[\(label)] contextualStrings: \(contextualStrings.count) terms")
        }

        try await analyzer.start(inputSequence: stream)
    }

    /// これまで analyzer が consume した音声まで強制的に final 確定する。session は継続する
    /// (`finalize(through:)` は `finalizeAndFinish` と違いセッションを終わらせない)。
    /// SpeakerSegmenter が話者ターン境界を検出したときにこれを呼び、長い掛け合いが 1 つの final に
    /// merge されるのを防ぐ(発話を話者の切れ目で区切る)。確定発話は ~100ms 後に results へ publish される。
    /// `through: nil` = 「最後に consume した音声まで」確定(未 consume なら何もしない)。
    public func finalizeThroughLatest() async {
        guard let analyzer else { return }
        do {
            try await analyzer.finalize(through: nil)
        } catch {
            ilog("[\(label)] finalize failed: \(error.localizedDescription)")
        }
    }

    /// 入力を締めてセッションを終える。stop 時に呼ぶ(mac は破棄で足りるので任意)。
    public func finish() async {
        inputBuilder?.finish()
        recognizerTask?.cancel()
        if let analyzer {
            try? await analyzer.finalizeAndFinishThroughEndOfInput()
        }
        analyzer = nil
        transcriber = nil
    }

    /// audio queue から同期で呼ばれる。AsyncStream.Continuation.yield は thread-safe。
    public func stream(_ buffer: AVAudioPCMBuffer) {
        streamCount += 1
        guard let analyzerFormat, let inputBuilder else {
            dlog("[Transcriber:\(label)] stream: not ready")
            return
        }
        do {
            let converted = try converter.convertBuffer(buffer, to: analyzerFormat)
            inputBuilder.yield(AnalyzerInput(buffer: converted))
        } catch {
            if streamCount % 500 == 0 {
                dlog("[Transcriber:\(label)] convert failed: \(error)")
            }
        }
    }

    // MARK: モデル確保 (AssetInventory)

    private func ensureModel(transcriber: SpeechTranscriber, locale: Locale) async throws {
        if let downloader = try await AssetInventory.assetInstallationRequest(supporting: [
            transcriber
        ]) {
            ilog("[\(label)] downloading language assets...")
            try await downloader.downloadAndInstall()
            ilog("[\(label)] assets installed")
        }

        let supported = await SpeechTranscriber.supportedLocales
        let isSupported = supported.contains {
            $0.identifier(.bcp47) == locale.identifier(.bcp47)
        }
        guard isSupported else {
            throw NSError(
                domain: "Transcriber", code: 3,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "locale \(locale.identifier) not supported. supported: \(supported.map { $0.identifier(.bcp47) })"
                ])
        }

        let reserved = await AssetInventory.reservedLocales
        if !reserved.contains(where: { $0.identifier(.bcp47) == locale.identifier(.bcp47) }) {
            try await AssetInventory.reserve(locale: locale)
        }
    }
}
