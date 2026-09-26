import Foundation

/// Jellyfin expresses all positions and durations in "ticks" (100 ns units).
public enum JellyfinTicks {
    public static let perSecond: Int64 = 10_000_000
    public static let perMillisecond: Int64 = 10_000

    public static func seconds(_ ticks: Int64) -> TimeInterval {
        TimeInterval(ticks) / TimeInterval(perSecond)
    }

    public static func seconds(_ ticks: Int64?) -> TimeInterval? {
        ticks.map { seconds($0) }
    }

    public static func ticks(seconds: TimeInterval) -> Int64 {
        guard seconds.isFinite, seconds > 0 else { return 0 }
        return Int64((seconds * TimeInterval(perSecond)).rounded())
    }

    public static func milliseconds(_ ticks: Int64) -> Int64 {
        ticks / perMillisecond
    }
}

public extension TimeInterval {
    /// Formats a duration as "1 Std. 42 Min." style is left to the UI; this returns "h:mm:ss" / "m:ss".
    var clockString: String {
        guard isFinite, self >= 0 else { return "0:00" }
        let total = Int(rounded())
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%d:%02d", minutes, seconds)
    }

    /// Whole minutes, rounded, for "115 min" style labels.
    var wholeMinutes: Int {
        guard isFinite, self > 0 else { return 0 }
        return Int((self / 60).rounded())
    }
}
