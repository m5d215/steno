import Foundation
import os

/// アプリ共通ログ。Console.app / `log stream` で拾える。
private let logger = Logger(subsystem: "com.m5d215.steno-mobile", category: "app")

func ilog(_ msg: String) { logger.info("\(msg, privacy: .public)") }
func dlog(_ msg: String) { logger.debug("\(msg, privacy: .public)") }
