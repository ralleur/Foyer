import Foundation
import FoyerFoundation

enum AppLog {
    static let buffer = LogBuffer(capacity: 800)

    static func configure() {
        let subsystem = Bundle.main.bundleIdentifier ?? "app.foyer.tv"
        #if DEBUG
        let level = LogLevel.debug
        #else
        let level = LogLevel.info
        #endif
        Log.shared.configure(sinks: [OSLogSink(subsystem: subsystem), buffer], minimumLevel: level)
        Log.info(.ui, "Foyer \(DeviceInfo.appVersion) starting on \(DeviceInfo.modelIdentifier)")
    }
}
