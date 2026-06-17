import Foundation

/// 1 確定発話を表すレコード。steno はこれを jsonl に「書くだけ」。
/// 話者は source(system=相手 / mic=自分)で区別する。話者分離モデルは持たない。
struct TranscriptRecord {
    let start: Date
    let source: String   // "system"(相手の声) | "mic"(自分)
    let app: String?     // source=system のみ: 確定時に出力中だったアプリ名(mic は nil)
    let text: String
}

/// 確定発話を `YYYY-MM-DD.jsonl`(JST ローカル日付)へ 1 行ずつ追記する。
/// append-only。steno(書くだけ) と後処理層(読むだけ) の唯一の契約面。
/// キー順を固定するため手動で JSON を構築する(JSONEncoder/辞書はキー順を保証しない)。
///
/// O_APPEND で開くのは意図的: 各 write はカーネルが見る実ファイル末尾へ atomic に追記され、
/// FileHandle が保持する offset に依存しない。sleep/wake で offset がズレても、二重起動が
/// 起きても、NUL hole(sparse) や上書きが発生しない(seekToEndOfFile を使う実装はスリープ復帰で
/// NUL 塊を生む)。
actor TranscriptWriter {
    private let baseDir: URL
    private var currentDateKey = ""
    private var handle: FileHandle?
    private var seq = 0

    private let isoFormatter: ISO8601DateFormatter
    private let dateKeyFormatter: DateFormatter

    init(baseDir: URL) {
        self.baseDir = baseDir

        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        iso.timeZone = TimeZone.current
        self.isoFormatter = iso

        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.dateFormat = "yyyy-MM-dd"
        df.timeZone = TimeZone.current
        self.dateKeyFormatter = df
    }

    func append(_ record: TranscriptRecord) {
        let dateKey = dateKeyFormatter.string(from: record.start)
        rotateIfNeeded(to: dateKey)
        guard let handle else { return }

        seq += 1
        // 固定キー順: ts, epoch, isFinal, seq, source, app?, text
        var parts: [String] = ["\"ts\":\(quote(isoFormatter.string(from: record.start)))"]
        parts.append("\"epoch\":\(record.start.timeIntervalSince1970)")
        parts.append("\"isFinal\":true")
        parts.append("\"seq\":\(seq)")
        parts.append("\"source\":\(quote(record.source))")
        if let app = record.app {
            parts.append("\"app\":\(quote(app))")
        }
        parts.append("\"text\":\(quote(record.text))")
        let json = "{" + parts.joined(separator: ",") + "}\n"

        do {
            try handle.write(contentsOf: Data(json.utf8))
        } catch {
            FileHandle.standardError.write(Data("[steno] write failed: \(error)\n".utf8))
        }
    }

    /// JSON 文字列リテラルにエスケープして両端を " で囲む。
    private func quote(_ s: String) -> String {
        var out = "\""
        for scalar in s.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if scalar.value < 0x20 {
                    out += String(format: "\\u%04x", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        out += "\""
        return out
    }

    /// 日付が変わったら(または初回)ファイルを開き直し、seq を 0 から振り直す。
    private func rotateIfNeeded(to dateKey: String) {
        guard dateKey != currentDateKey else { return }

        try? handle?.close()
        handle = nil

        let fm = FileManager.default
        try? fm.createDirectory(at: baseDir, withIntermediateDirectories: true)
        let url = baseDir.appendingPathComponent("\(dateKey).jsonl")

        let fd = open(url.path, O_WRONLY | O_APPEND | O_CREAT, 0o644)
        guard fd >= 0 else {
            FileHandle.standardError.write(
                Data("[steno] cannot open \(url.path): errno \(errno)\n".utf8))
            return
        }
        handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        currentDateKey = dateKey
        seq = 0
    }

    func close() {
        try? handle?.close()
        handle = nil
    }
}
