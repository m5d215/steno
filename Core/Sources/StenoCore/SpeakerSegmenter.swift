@preconcurrency import AVFoundation
import FluidAudio
import Foundation

/// Streaming Sortformer(FluidAudio / CoreML)で system 音声の話者ターン境界を検出する。
/// 目的は話者の特定ではなく「別の人が話し始めたら発話を区切る」こと。検出した境界で
/// `onTurnBoundary` を呼び、呼び出し側が `Transcriber.finalizeThroughLatest()` を叩いて発話を切る。
/// ラベル(speakerIndex)の正確さは要求しない。境界さえ出れば最低限ゴール。
///
/// 制約への対処:
///   - ANE 競合: SpeechAnalyzer×2 が ANE を握っているため、diarizer の compute units は
///     `.cpuAndGPU` に固定して ANE を外す(同時 CoreML on ANE での E5RT クラッシュ回避)。
///   - thread-safety: SortformerDiarizer は **non thread-safe**。audio callback(Core Audio
///     スレッド)から直接触らず、専用 serial queue 上でのみアクセスする。feed() は float 抽出だけ
///     audio スレッドで行い、推論は queue に逃がす(audio render を CoreML 推論でブロックしない)。
public final class SpeakerSegmenter: @unchecked Sendable {
    private let onTurnBoundary: @Sendable () -> Void
    private let queue = DispatchQueue(label: "com.m5d215.steno.diar", qos: .userInitiated)

    private var diarizer: SortformerDiarizer?
    /// 確定済みの「今の話者」。境界はここからの変化で判定する。
    private var liveSpeaker: Int?
    /// 話者変化の候補と、それが連続して観測された回数(debounce 用)。
    private var candidate: Int?
    private var candidateHits = 0
    /// 候補が何回連続したら境界として確定するか。process() の非 nil update は ~0.48s 間隔なので
    /// 2 ≈ 約 1s の確認。tentative の一時的な [0,1] フリッカで誤爆しない最小限。
    private let debounceHits = 2

    /// 直近に実際に発話を切った時刻。min-cut-interval の基準。
    private var lastCutAt: Date?
    /// この秒数以内の話者 flip では切らない。相槌(「はい」等)の短い割り込みで極小レコードが量産される
    /// のを抑える。本来の話者が interval 内に戻れば spk==liveSpeaker に戻り、変化自体が消えて吸収される。
    /// 代償: これ未満の本物の短いターンも merge される(区切りの目的には許容)。tunable。
    private let minCutInterval: TimeInterval = 1.5

    public init(onTurnBoundary: @escaping @Sendable () -> Void) {
        self.onTurnBoundary = onTurnBoundary
    }

    /// モデルを HuggingFace(初回のみ download、以降 cache)から読み込んで初期化する。async。
    /// load 所要を ilog に出す(cache 済みで ~1.3s)。失敗は呼び出し側で catch され、素の動作に縮退する。
    public func start(config: SortformerConfig = .default) async throws {
        let t0 = Date()
        let models = try await SortformerModels.loadFromHuggingFace(
            config: config, computeUnits: .cpuAndGPU)
        let d = SortformerDiarizer(config: config)
        d.initialize(models: models)
        queue.sync { self.diarizer = d }
        ilog("[diar] ready in \(String(format: "%.1f", Date().timeIntervalSince(t0)))s (cpuAndGPU)")
    }

    /// audio callback(Core Audio スレッド)から同期で呼ばれる。mono float を抜いて queue に渡す。
    public func feed(_ buffer: AVAudioPCMBuffer) {
        guard let ch = buffer.floatChannelData else { return }
        let n = Int(buffer.frameLength)
        guard n > 0 else { return }
        let samples = Array(UnsafeBufferPointer(start: ch[0], count: n))
        let rate = buffer.format.sampleRate
        queue.async { [weak self] in self?.process(samples, rate: rate) }
    }

    /// queue 上でのみ呼ばれる(diarizer の単一スレッドアクセスを保証)。
    private func process(_ samples: [Float], rate: Double) {
        guard let diarizer else { return }
        do {
            guard let update = try diarizer.process(samples: samples, sourceSampleRate: rate)
            else { return }
            // live な話者は tentative 側に最も早く出る(finalized は数秒遅れるので cut が間延びする)。
            // tentative が空なら finalized で代用。最新フレーム(endFrame 最大)の話者を live とみなす。
            let segs =
                update.tentativeSegments.isEmpty ? update.finalizedSegments : update.tentativeSegments
            guard let latest = segs.max(by: { $0.endFrame < $1.endFrame }) else { return }
            let spk = latest.speakerIndex

            // live と同じなら候補をリセット。違えば debounce で連続確認してから境界確定。
            if spk == liveSpeaker {
                candidate = nil
                candidateHits = 0
                return
            }
            if spk == candidate {
                candidateHits += 1
            } else {
                candidate = spk
                candidateHits = 1
            }
            guard candidateHits >= debounceHits else { return }

            // min-cut-interval: 直近の cut から minCutInterval 未満なら切らない(liveSpeaker 据え置き、
            // candidate も触らない)。短い割り込みは、本来の話者が戻れば上の spk==liveSpeaker 分岐で
            // 消える。本物のターン交代が interval を跨いで続けば、次の update で確定して切れる。
            if let lastCutAt, Date().timeIntervalSince(lastCutAt) < minCutInterval {
                return
            }

            let prev = liveSpeaker
            liveSpeaker = spk
            candidate = nil
            candidateHits = 0
            // 初回(prev=nil)はストリーム開始なので境界として切らない(lastCutAt も更新しない)。
            if let prev {
                lastCutAt = Date()
                ilog(
                    "[diar] turn boundary spk\(prev) -> spk\(spk) "
                        + "@\(String(format: "%.2f", latest.startTime))s")
                onTurnBoundary()
            }
        } catch {
            ilog("[diar] process error: \(error.localizedDescription)")
        }
    }
}
