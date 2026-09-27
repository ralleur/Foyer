import Foundation
import FoyerFoundation

enum AppLog {
    static let buffer = LogBuffer(capacity: 800)
    /// `Library/Caches/Logs/foyer.log` in the app container (purgeable; pulled with `Scripts/device-logs.sh`).
    static let fileURL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Logs", isDirectory: true).appendingPathComponent("foyer.log")
    static let file = FileLogSink(url: fileURL)

    static func configure() {
        let subsystem = Bundle.main.bundleIdentifier ?? "app.foyer.tv"
        #if DEBUG
        let level = LogLevel.debug
        #else
        let level = LogLevel.info
        #endif
        Log.shared.configure(sinks: [OSLogSink(subsystem: subsystem), buffer, file], minimumLevel: level)
        Log.info(.ui, "Foyer \(DeviceInfo.appVersion) starting on \(DeviceInfo.modelIdentifier) — log file \(fileURL.path)")
    }
}
