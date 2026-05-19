import Foundation
import os

public struct LogChannel: Sendable {
    private let logger: Logger
    private let category: String

    init(category: String) {
        self.logger = Logger(subsystem: "io.wledcast.native", category: category)
        self.category = category
    }

    public func debug(_ message: String) {
        logger.debug("\(message, privacy: .public)")
        FileLog.shared.append(level: "debug", category: category, message: message)
    }

    public func info(_ message: String) {
        logger.info("\(message, privacy: .public)")
        FileLog.shared.append(level: "info", category: category, message: message)
    }

    public func notice(_ message: String) {
        logger.notice("\(message, privacy: .public)")
        FileLog.shared.append(level: "notice", category: category, message: message)
    }

    public func warning(_ message: String) {
        logger.warning("\(message, privacy: .public)")
        FileLog.shared.append(level: "warning", category: category, message: message)
    }

    public func error(_ message: String) {
        logger.error("\(message, privacy: .public)")
        FileLog.shared.append(level: "error", category: category, message: message)
    }
}

public enum Log {
    public static let app = LogChannel(category: "app")
    public static let permissions = LogChannel(category: "permissions")
    public static let discovery = LogChannel(category: "discovery")
    public static let session = LogChannel(category: "session")
    public static let transport = LogChannel(category: "transport")
    public static let capture = LogChannel(category: "capture")
}
