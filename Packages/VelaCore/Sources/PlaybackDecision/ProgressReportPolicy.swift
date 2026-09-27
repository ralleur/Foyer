import Foundation

/// Decides when playback progress is reported to the server.
/// Timer-based reports every `interval` seconds while playing, plus immediate
/// reports on state changes; never more than one report per `minimumSpacing`.
public struct ProgressReportPolicy: Sendable, Hashable {
    public var interval: TimeInterval
    public var minimumSpacing: TimeInterval

    public init(interval: TimeInterval = 10, minimumSpacing: TimeInterval = 1) {
        self.interval = interval
        self.minimumSpacing = minimumSpacing
    }

    public enum Trigger: Sendable, Hashable {
        case timer
        case pause
        case resume
        case seek
        case trackChange
    }

    public func shouldReport(trigger: Trigger, now: Date, lastReport: Date?, isPlaying: Bool) -> Bool {
        guard let lastReport else { return true }
        let elapsed = now.timeIntervalSince(lastReport)
        switch trigger {
        case .timer:
            return isPlaying && elapsed >= interval - 0.05
        case .pause, .resume, .seek, .trackChange:
            return elapsed >= minimumSpacing
        }
    }
}
