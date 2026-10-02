import Foundation
import JellyfinKit

/// Where playback should start for an item.
public enum ResumePolicy {
    /// Ignore saved positions inside the first seconds and within the last stretch of the file.
    public static let minimumResume: TimeInterval = 20
    public static let endThreshold: TimeInterval = 15

    public static func resumePosition(for item: BaseItem) -> TimeInterval? {
        guard let saved = item.resumePosition, saved > minimumResume else { return nil }
        if let runtime = item.runtime, runtime > 0, saved > runtime - endThreshold { return nil }
        return saved
    }

    /// True when the primary action should read "Continue" rather than "Play".
    public static func canResume(_ item: BaseItem) -> Bool {
        resumePosition(for: item) != nil
    }
}
