import Foundation

/// プロセスの stdout/stderr を configDir のファイルへ恒久リダイレクトする。**main の最初に呼ぶ。**
///
/// GUI(LaunchServices / Finder)起動だと fd 1/2 は /dev/null に繋がれ、stderr に出るもの——
/// `fatalError` のバックトレース、`dlog`、フレームワーク警告、未捕捉例外のメッセージなど ilog を
/// 通らない出力——が全部消える。`open --stderr` は make run でしか効かないので、アプリ自身が起動
/// 直後に fd を張り替えて、起動方法に依らず必ずファイルに残す。
///
/// steno.log(`StenoLog`、時刻付き・重要イベントのみの綺麗なログ)とは別物。こちらは生の
/// firehose(ilog の重複 + dlog + crash + フレームワーク)。診断はまず steno.log、深掘りで stderr.log。
/// 1 世代だけローテート(前回=クラッシュした回の出力を保全しつつ無限肥大を防ぐ)。
func redirectStandardStreams() {
    let dir = AppController.configDir()
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    func redirect(_ name: String, _ stream: UnsafeMutablePointer<FILE>) {
        let url = dir.appending(path: name)
        let prev = dir.appending(path: name + ".1")
        try? FileManager.default.removeItem(at: prev)
        try? FileManager.default.moveItem(at: url, to: prev)
        _ = freopen(url.path, "w", stream)
    }
    redirect("stdout.log", stdout)
    redirect("stderr.log", stderr)
    setvbuf(stdout, nil, _IOLBF, 0)  // ファイル相手だと block-buffer 化して print が遅延 → 行バッファに
    setvbuf(stderr, nil, _IONBF, 0)  // stderr は無バッファ(クラッシュ直前の出力を取りこぼさない)
}

/// STENO_DEBUG が設定されているときだけ stderr に出すデバッグログ。既定では静か。
let stenoDebug = ProcessInfo.processInfo.environment["STENO_DEBUG"] != nil

func dlog(_ message: String) {
    guard stenoDebug else { return }
    FileHandle.standardError.write(Data("\(message)\n".utf8))
}

/// 常に出す重要ログ(起動・権限・エラー・liveness)。stderr とローカルログファイル両方へ。
/// `open` 起動の .app は stderr を捨てるので、事後の障害解析にはファイルが命綱になる。
func ilog(_ message: String) {
    FileHandle.standardError.write(Data("[steno] \(message)\n".utf8))
    StenoLog.shared.write(message)
}

/// ilog をローカルファイル(`configDir/steno.log`)にも残す軽量ロガー。
///
/// filtering の前提: ilog は低頻度(起動・権限・エラー・watchdog・tap/mic の recreate)。
/// 毎バッファでは呼ばないので lock の contention は無視できる。IOProc hot path からは呼ばれない。
///
/// 設計:
/// - O_APPEND で開く(sleep/wake で offset がズレても、二重起動でも末尾へ atomic 追記。TranscriptWriter と同思想)
/// - 1 行ごとにローカル時刻のタイムスタンプを付ける(transcript の gap と時刻で突き合わせるため)
/// - cap を超えたら 1 世代だけローテート(`steno.log` → `steno.log.1`)。無限肥大を防ぐ保険
/// - プロセス起動時に区切りマーカーを書く(再起動の境界を後から見つけられる)
final class StenoLog: @unchecked Sendable {
    static let shared = StenoLog()

    private let lock = NSLock()
    private var handle: FileHandle?
    private let url: URL
    private let rotateURL: URL
    private var bytes = 0
    private let cap = 4 * 1024 * 1024  // 4MB で 1 世代ローテート

    private let formatter: DateFormatter

    private init() {
        let dir = AppController.configDir()
        url = dir.appending(path: "steno.log")
        rotateURL = dir.appending(path: "steno.log.1")

        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        f.timeZone = TimeZone.current
        formatter = f

        openFile()
        // 起動マーカー。各プロセスの開始を区切る(再起動境界 = transcript の seq リセットと対応)。
        writeRaw("──── steno session start (pid \(ProcessInfo.processInfo.processIdentifier)) ────")
    }

    /// タイムスタンプを付けて 1 行追記。
    func write(_ message: String) {
        writeRaw(message)
    }

    private func writeRaw(_ message: String) {
        lock.lock()
        defer { lock.unlock() }
        guard let handle else { return }
        let line = "\(formatter.string(from: Date())) \(message)\n"
        let data = Data(line.utf8)
        do {
            try handle.write(contentsOf: data)
            bytes += data.count
            if bytes >= cap { rotate() }
        } catch {
            // ログの書き込み失敗で本体を巻き込まない。stderr にだけ残す。
            FileHandle.standardError.write(Data("[steno] log write failed: \(error)\n".utf8))
        }
    }

    private func openFile() {
        let fm = FileManager.default
        try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let fd = Foundation.open(url.path, O_WRONLY | O_APPEND | O_CREAT, 0o644)
        guard fd >= 0 else {
            FileHandle.standardError.write(
                Data("[steno] cannot open log \(url.path): errno \(errno)\n".utf8))
            return
        }
        handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        bytes = ((try? fm.attributesOfItem(atPath: url.path))?[.size] as? Int) ?? 0
    }

    /// 現ファイルを `.1` へ退避して開き直す(lock 保持下で呼ぶ)。
    private func rotate() {
        try? handle?.close()
        handle = nil
        let fm = FileManager.default
        try? fm.removeItem(at: rotateURL)
        try? fm.moveItem(at: url, to: rotateURL)
        openFile()  // 退避後 url は不在 → 新規作成・bytes は 0 に戻る
    }
}
