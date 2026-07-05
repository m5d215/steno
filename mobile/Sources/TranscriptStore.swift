import Foundation

/// 1 確定発話 = 1 レコード。ローカル jsonl と送信ペイロードの唯一の契約面。
/// `seq` はファイルを跨いだ **グローバル単調増加**(steno の日次リセットとは違う)。
/// 送信カーソルとサーバ側 dedup を `(deviceId, seq)` で単純にするための選択。
struct WireRecord: Sendable, Codable, Identifiable {
    let deviceId: String
    let ts: String      // ISO 8601 ローカル時刻
    let epoch: Double   // Unix 秒
    let seq: Int        // グローバル単調増加
    let source: String  // "mic"(iOS は mic 一本)
    let text: String

    var id: Int { seq }
}

/// 確定発話を **ローカル jsonl に append(SSOT)** し、未送信ぶんを in-memory キューに積む。
/// capture と network を分離する: capture は「まず書く」だけ、送信は Shipper が別で追いかける。
///
/// - jsonl は `Documents/transcripts/YYYY-MM-DD.jsonl`(ローカル日付)へ O_APPEND で追記。
/// - `seq` / `lastShippedSeq` は UserDefaults に永続。
/// - 起動時に jsonl から未送信(seq > lastShippedSeq)を復元 → アプリ再起動を跨いで取りこぼさない。
actor TranscriptStore {
    private let baseDir: URL
    private var handle: FileHandle?
    private var currentDateKey = ""

    private var lastSeq: Int
    private var lastShippedSeq: Int
    private var pending: [WireRecord] = []

    private let iso: ISO8601DateFormatter
    private let dateKeyFmt: DateFormatter
    private let encoder: JSONEncoder

    init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        baseDir = docs.appendingPathComponent("transcripts", isDirectory: true)
        try? FileManager.default.createDirectory(at: baseDir, withIntermediateDirectories: true)

        lastSeq = UserDefaults.standard.integer(forKey: "lastSeq")
        lastShippedSeq = UserDefaults.standard.integer(forKey: "lastShippedSeq")

        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        f.timeZone = .current
        iso = f

        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.dateFormat = "yyyy-MM-dd"
        df.timeZone = .current
        dateKeyFmt = df

        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder = enc

        // 起動時に jsonl から未送信ぶんを復元(actor init は nonisolated なので self を使わない
        // static ヘルパで計算して pending に入れる)。
        pending = Self.recoverUnshipped(baseDir: baseDir, after: lastShippedSeq)
    }

    /// 確定発話を記録する。jsonl へ追記し、送信キューに積んで、そのレコードを返す。
    func append(text: String, at date: Date) -> WireRecord {
        lastSeq += 1
        UserDefaults.standard.set(lastSeq, forKey: "lastSeq")

        let rec = WireRecord(
            deviceId: Config.deviceId,
            ts: iso.string(from: date),
            epoch: date.timeIntervalSince1970,
            seq: lastSeq,
            source: "mic",
            text: text)

        writeLine(rec, date: date)
        pending.append(rec)
        return rec
    }

    /// 送信対象の先頭バッチ(seq 昇順)。
    func pendingBatch(max: Int) -> [WireRecord] {
        Array(pending.sorted { $0.seq < $1.seq }.prefix(max))
    }

    /// `seq` まで送信済みにする。キューから外し、カーソルを進める。
    func markShipped(throughSeq seq: Int) {
        pending.removeAll { $0.seq <= seq }
        if seq > lastShippedSeq {
            lastShippedSeq = seq
            UserDefaults.standard.set(seq, forKey: "lastShippedSeq")
        }
    }

    var pendingCount: Int { pending.count }

    // MARK: - jsonl 追記

    private func writeLine(_ rec: WireRecord, date: Date) {
        let dateKey = dateKeyFmt.string(from: date)
        rotateIfNeeded(to: dateKey)
        guard let handle else { return }
        guard let data = try? encoder.encode(rec) else { return }
        var line = data
        line.append(0x0a)  // "\n"
        do {
            try handle.write(contentsOf: line)
        } catch {
            ilog("write failed: \(error.localizedDescription)")
        }
    }

    private func rotateIfNeeded(to dateKey: String) {
        guard dateKey != currentDateKey else { return }
        try? handle?.close()
        handle = nil

        let url = baseDir.appendingPathComponent("\(dateKey).jsonl")
        let fd = open(url.path, O_WRONLY | O_APPEND | O_CREAT, 0o644)
        guard fd >= 0 else {
            ilog("cannot open \(url.lastPathComponent): errno \(errno)")
            return
        }
        handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        currentDateKey = dateKey
    }

    // MARK: - 起動時の未送信復元

    private static func recoverUnshipped(baseDir: URL, after lastShipped: Int) -> [WireRecord] {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: baseDir, includingPropertiesForKeys: nil)
        else { return [] }
        let decoder = JSONDecoder()
        var recovered: [WireRecord] = []
        for url in files where url.pathExtension == "jsonl" {
            guard let content = try? String(contentsOf: url, encoding: .utf8) else { continue }
            for line in content.split(separator: "\n") {
                guard let data = line.data(using: .utf8),
                    let rec = try? decoder.decode(WireRecord.self, from: data),
                    rec.seq > lastShipped
                else { continue }
                recovered.append(rec)
            }
        }
        if !recovered.isEmpty {
            ilog("recovered \(recovered.count) unshipped records")
        }
        return recovered.sorted { $0.seq < $1.seq }
    }
}
