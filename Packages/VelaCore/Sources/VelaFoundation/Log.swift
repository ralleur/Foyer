import Foundation
#if canImport(os)
import os
#endif

/// Structured logging categories used across the app.
public enum LogCategory: String, Sendable, CaseIterable, Codable {
    case network = "NETWORK"
    case jellyfin = "JELLYFIN"
    case playback = "PLAYBACK"
    case subtitle = "SUBTITLE"
    case audio = "AUDIO"
    case ui = "UI"
    case cache = "CACHE"
}

public enum LogLevel: Int, Sendable, Comparable, Codable {
    case debug = 0
    case info = 1
    case notice = 2
    case warning = 3
    case error = 4

    public static func < (lhs: LogLevel, rhs: LogLevel) -> Bool { lhs.rawValue < rhs.rawValue }

    public var label: String {
        switch self {
        case .debug: "DEBUG"
        case .info: "INFO"
        case .notice: "NOTICE"
        case .warning: "WARN"
        case .error: "ERROR"
        }
    }
}

public struct LogEntry: Sendable, Identifiable, Hashable, Codable {
    public let id: UUID
    public let date: Date
    public let level: LogLevel
    public let category: LogCategory
    public let message: String

    public init(id: UUID = UUID(), date: Date = Date(), level: LogLevel, category: LogCategory, message: String) {
        self.id = id
        self.date = date
        self.level = level
        self.category = category
        self.message = message
    }

    public var formatted: String {
        "\(Log.timestampFormatter.value.string(from: date)) [\(category.rawValue)] \(level.label): \(message)"
    }
}

public protocol LogSink: Sendable {
    func write(_ entry: LogEntry)
}

/// In-memory ring buffer used by the debug screen. Thread-safe.
public final class LogBuffer: LogSink, @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [LogEntry] = []
    private let capacity: Int

    public init(capacity: Int = 600) {
        self.capacity = capacity
    }

    public func write(_ entry: LogEntry) {
        lock.lock()
        defer { lock.unlock() }
        entries.append(entry)
        if entries.count > capacity {
            entries.removeFirst(entries.count - capacity)
        }
    }

    public var snapshot: [LogEntry] {
        lock.lock()
        defer { lock.unlock() }
        return entries
    }

    public func clear() {
        lock.lock()
        entries.removeAll()
        lock.unlock()
    }
}

/// Prints to stdout. Used on Linux and in tests.
public struct ConsoleLogSink: LogSink {
    public init() {}
    public func write(_ entry: LogEntry) {
        print(entry.formatted)
    }
}

#if canImport(os)
/// Forwards to the unified logging system (Console.app / `log stream`).
public struct OSLogSink: LogSink {
    private let loggers: [LogCategory: Logger]

    public init(subsystem: String) {
        var dict: [LogCategory: Logger] = [:]
        for category in LogCategory.allCases {
            dict[category] = Logger(subsystem: subsystem, category: category.rawValue)
        }
        loggers = dict
    }

    public func write(_ entry: LogEntry) {
        guard let logger = loggers[entry.category] else { return }
        // Messages are already redacted; mark public so they show in Console.
        switch entry.level {
        case .debug: logger.debug("\(entry.message, privacy: .public)")
        case .info: logger.info("\(entry.message, privacy: .public)")
        case .notice: logger.notice("\(entry.message, privacy: .public)")
        case .warning: logger.warning("\(entry.message, privacy: .public)")
        case .error: logger.error("\(entry.message, privacy: .public)")
        }
    }
}
#endif

/// Central logging facade. Cheap to call; message construction is lazy.
///
/// Secrets: access tokens registered via `registerSecret` and well-known token
/// query parameters / headers are scrubbed from every message before it reaches a sink.
public final class Log: @unchecked Sendable {
    public static let shared = Log()

    static let timestampFormatter = UncheckedSendable<DateFormatter>({
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }())

    private let lock = NSLock()
    private var sinks: [any LogSink] = [ConsoleLogSink()]
    private var minimumLevel: LogLevel = .debug
    private var secrets: [String] = []

    public init() {}

    public func configure(sinks: [any LogSink], minimumLevel: LogLevel = .debug) {
        lock.lock()
        self.sinks = sinks
        self.minimumLevel = minimumLevel
        lock.unlock()
    }

    /// Registers a secret string (e.g. an access token) that must never appear in logs.
    public func registerSecret(_ secret: String) {
        guard secret.count >= 6 else { return }
        lock.lock()
        if !secrets.contains(secret) { secrets.append(secret) }
        lock.unlock()
    }

    public func removeSecret(_ secret: String) {
        lock.lock()
        secrets.removeAll { $0 == secret }
        lock.unlock()
    }

    public func log(_ level: LogLevel, _ category: LogCategory, _ message: @autoclosure () -> String) {
        lock.lock()
        let level_ok = level >= minimumLevel
        let currentSinks = sinks
        let currentSecrets = secrets
        lock.unlock()
        guard level_ok else { return }
        let redacted = Log.redact(message(), secrets: currentSecrets)
        let entry = LogEntry(level: level, category: category, message: redacted)
        for sink in currentSinks {
            sink.write(entry)
        }
    }

    // MARK: Convenience

    public static func debug(_ category: LogCategory, _ message: @autoclosure () -> String) {
        shared.log(.debug, category, message())
    }

    public static func info(_ category: LogCategory, _ message: @autoclosure () -> String) {
        shared.log(.info, category, message())
    }

    public static func notice(_ category: LogCategory, _ message: @autoclosure () -> String) {
        shared.log(.notice, category, message())
    }

    public static func warning(_ category: LogCategory, _ message: @autoclosure () -> String) {
        shared.log(.warning, category, message())
    }

    public static func error(_ category: LogCategory, _ message: @autoclosure () -> String) {
        shared.log(.error, category, message())
    }

    // MARK: Redaction

    private static let tokenPatterns = UncheckedSendable<[NSRegularExpression]>({
        let patterns = [
            // api_key=abc / ApiKey=abc / X-Emby-Token=abc  (query parameters)
            "(?i)((?:api_key|apikey|x-emby-token|x-mediabrowser-token|access_token)=)([^&\\s\"']+)",
            // Token="abc" inside the MediaBrowser authorization header
            "(?i)(token=\")([^\"]+)(\")",
            // "AccessToken":"abc" in JSON bodies
            "(?i)(\"accesstoken\"\\s*:\\s*\")([^\"]+)(\")",
            // Pw / Password JSON fields
            "(?i)(\"(?:pw|password|secret)\"\\s*:\\s*\")([^\"]*)(\")",
        ]
        return patterns.compactMap { try? NSRegularExpression(pattern: $0) }
    }())

    public static func redact(_ message: String, secrets: [String] = []) -> String {
        var result = message
        for regex in tokenPatterns.value {
            let range = NSRange(result.startIndex..., in: result)
            let template = regex.numberOfCaptureGroups >= 3 ? "$1•••$3" : "$1•••"
            result = regex.stringByReplacingMatches(in: result, range: range, withTemplate: template)
        }
        for secret in secrets where !secret.isEmpty {
            result = result.replacingOccurrences(of: secret, with: "•••")
        }
        return result
    }
}
