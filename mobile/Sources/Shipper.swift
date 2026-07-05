import Foundation

/// 未送信レコードを宛先へ POST し続ける。capture からは独立して動く。
///
/// - `POST <endpoint>/ingest`  body = WireRecord の JSON 配列 / header `Authorization: Bearer <token>`
/// - サーバは受理した最大 seq を `{"acked": <seq>}` で返す(無ければ送ったバッチ末尾の seq を採用)。
/// - at-least-once。サーバ側は `(deviceId, seq)` で冪等 dedup する前提。
/// - 失敗(PC 停止 / Tailscale 未接続 等)は指数 backoff で retry。復帰したら溜まったぶんを drain。
final class Shipper: @unchecked Sendable {
    private let store: TranscriptStore
    private let onStatus: @MainActor (String) -> Void
    private var task: Task<Void, Never>?

    init(store: TranscriptStore, onStatus: @escaping @MainActor (String) -> Void) {
        self.store = store
        self.onStatus = onStatus
    }

    func start() {
        task = Task { await loop() }
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    private func loop() async {
        var backoff: Double = 1
        while !Task.isCancelled {
            let batch = await store.pendingBatch(max: 50)
            if batch.isEmpty {
                try? await Task.sleep(for: .seconds(1))
                continue
            }
            guard let url = ingestURL(Config.endpoint) else {
                await setStatus("宛先 URL が未設定")
                try? await Task.sleep(for: .seconds(3))
                continue
            }
            do {
                let acked = try await post(batch, to: url, token: Config.token)
                await store.markShipped(throughSeq: acked)
                backoff = 1
                await setStatus("送信 OK (〜seq \(acked), 残 \(await store.pendingCount))")
            } catch {
                await setStatus("送信失敗: \(error.localizedDescription) — \(Int(backoff))s 後に再試行")
                try? await Task.sleep(for: .seconds(backoff))
                backoff = min(backoff * 2, 30)
            }
        }
    }

    private func ingestURL(_ base: String) -> URL? {
        let trimmed = base.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, var url = URL(string: trimmed) else { return nil }
        url.append(path: "ingest")
        return url
    }

    private struct Ack: Decodable { let acked: Int? }

    /// バッチを POST し、サーバが ack した最大 seq を返す。
    private func post(_ batch: [WireRecord], to url: URL, token: String) async throws -> Int {
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !token.isEmpty {
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        req.httpBody = try JSONEncoder().encode(batch)
        req.timeoutInterval = 15

        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else {
            throw NSError(domain: "Shipper", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "no HTTP response"])
        }
        guard (200..<300).contains(http.statusCode) else {
            throw NSError(domain: "Shipper", code: http.statusCode,
                userInfo: [NSLocalizedDescriptionKey: "HTTP \(http.statusCode)"])
        }
        // ack があればそれを、無ければ送ったバッチ末尾の seq を送信済みとみなす。
        let ack = try? JSONDecoder().decode(Ack.self, from: data)
        return ack?.acked ?? (batch.last?.seq ?? 0)
    }

    private func setStatus(_ s: String) async {
        await onStatus(s)
    }
}
