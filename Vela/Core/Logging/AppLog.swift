import Foundation
import VelaFoundation

enum AppLog {
    static let buffer = LogBuffer(capacity: 800)
    /// `Library/Caches/Logs/vela.log` in the app container (purgeable; pulled with `Scripts/device-logs.sh`).
    static let fileURL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Logs", isDirectory: true).appendingPathComponent("vela.log")
    static let file = FileLogSink(url: fileURL)

    static func configure() {
        let subsystem = Bundle.main.bundleIdentifier ?? "app.vela.tv"
        #if DEBUG
        let level = LogLevel.debug
        #else
        let level = LogLevel.info
        #endif
        Log.shared.configure(sinks: [OSLogSink(subsystem: subsystem), buffer, file], minimumLevel: level)
        Log.info(.ui, "Vela \(DeviceInfo.appVersion) starting on \(DeviceInfo.modelIdentifier) — log file \(fileURL.path)")
        let arguments = ProcessInfo.processInfo.arguments.dropFirst()
        if !arguments.isEmpty { Log.info(.ui, "Launch arguments: \(arguments.joined(separator: " "))") }
    }
}
