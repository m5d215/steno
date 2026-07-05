import Foundation
import os

/// Core エンジンのログ。既定は os.Logger へ出す。アプリが `sink` を刺すと、そちらにも流す
/// (mac は steno.log の StenoLog へ橋渡しして、エンジンのログも従来どおりファイルに残す)。
/// sink は起動直後に一度だけ設定する前提。
public enum StenoCoreLog {
    nonisolated(unsafe) public static var sink: (@Sendable (String) -> Void)?
    static let logger = Logger(subsystem: "com.m5d215.steno.core", category: "engine")
}

func ilog(_ message: String) {
    StenoCoreLog.logger.info("\(message, privacy: .public)")
    StenoCoreLog.sink?(message)
}

func dlog(_ message: String) {
    StenoCoreLog.logger.debug("\(message, privacy: .public)")
}
