import Foundation
import JellyfinKit

/// Which skip affordance to show at a moment in time.
public enum SkipPrompt: Sendable, Hashable {
    case none
    case skipIntro(to: TimeInterval)
    case skipRecap(to: TimeInterval)
    case skipCommercial(to: TimeInterval)
    /// Credits are rolling; offer the next episode (or just skip to the end).
    case nextEpisode(creditsStart: TimeInterval, mediaEnd: TimeInterval)

    public var target: TimeInterval? {
        switch self {
        case .none: nil
        case let .skipIntro(to), let .skipRecap(to), let .skipCommercial(to): to
        case let .nextEpisode(_, end): end
        }
    }
}

/// Stateless policy: given segments, the current time and what the user dismissed,
/// decide whether a skip button should be visible.
public struct SkipSegmentPolicy: Sendable, Hashable {
    /// Keep the intro button on screen at most this long after the segment starts.
    public var maximumVisibleDuration: TimeInterval
    /// Do not offer skipping segments shorter than this.
    public var minimumSegmentDuration: TimeInterval
    /// Do not show a skip button when fewer seconds than this remain in the segment.
    public var minimumRemaining: TimeInterval

    public init(maximumVisibleDuration: TimeInterval = 12, minimumSegmentDuration: TimeInterval = 4, minimumRemaining: TimeInterval = 2) {
        self.maximumVisibleDuration = maximumVisibleDuration
        self.minimumSegmentDuration = minimumSegmentDuration
        self.minimumRemaining = minimumRemaining
    }

    public func prompt(at time: TimeInterval, segments: [MediaSegment], mediaDuration: TimeInterval,
                       dismissed: Set<String>, hasNextEpisode: Bool) -> SkipPrompt {
        for segment in segments where segment.duration >= minimumSegmentDuration && !dismissed.contains(segment.id) {
            guard segment.contains(time) else { continue }
            let remaining = segment.end - time
            guard remaining >= minimumRemaining else { continue }
            switch segment.type {
            case .intro:
                guard time - segment.start <= maximumVisibleDuration else { continue }
                return .skipIntro(to: segment.end)
            case .recap:
                guard time - segment.start <= maximumVisibleDuration else { continue }
                return .skipRecap(to: segment.end)
            case .commercial, .preview:
                return .skipCommercial(to: segment.end)
            case .outro:
                // Credits: the prompt stays until the end so the user can jump to the next episode any time.
                let end = mediaDuration > 0 ? min(mediaDuration, segment.end) : segment.end
                return .nextEpisode(creditsStart: segment.start, mediaEnd: end)
            default:
                continue
            }
        }
        return .none
    }
}

/// When to start the autoplay countdown for the next episode when no credits marker exists.
public struct NextEpisodeCountdownPolicy: Sendable, Hashable {
    public var countdownSeconds: Int
    /// Without an outro marker, start the countdown this many seconds before the end.
    public var fallbackLeadTime: TimeInterval

    public init(countdownSeconds: Int = 10, fallbackLeadTime: TimeInterval = 20) {
        self.countdownSeconds = countdownSeconds
        self.fallbackLeadTime = fallbackLeadTime
    }

    /// Returns the time at which the countdown should start, or nil when autoplay is not applicable.
    public func countdownStart(mediaDuration: TimeInterval, outro: MediaSegment?) -> TimeInterval? {
        guard mediaDuration > 60 else { return nil }
        if let outro, outro.duration >= 5 {
            return max(outro.start, mediaDuration - TimeInterval(countdownSeconds) - max(0, outro.duration - TimeInterval(countdownSeconds)))
        }
        return max(0, mediaDuration - fallbackLeadTime)
    }
}

/// Intro, recap, credits and preview segments from chapter names ("Intro", "Opening Credits", "Previously on…",
/// "Abspann", …) for episodes the server has no media segments for. Server segments (Intro Skipper) win per type.
public enum ChapterSegments {
    private static let names: [(MediaSegmentType, [String])] = [
        (.recap, ["recap", "previously", "previously on", "zuvor", "was bisher geschah", "rückblick", "bisher bei"]),
        (.intro, ["intro", "opening", "opening credits", "opening titles", "title sequence", "main title", "main titles",
                  "vorspann", "titelsequenz", "op"]),
        (.outro, ["credits", "end credits", "closing credits", "ending credits", "end titles", "outro", "ending", "ed",
                  "abspann", "nachspann"]),
        (.preview, ["preview", "next time", "next episode", "vorschau", "nächstes mal"]),
    ]

    public static func type(forChapterName raw: String?) -> MediaSegmentType? {
        guard let raw else { return nil }
        let name = raw.lowercased().trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        guard !name.isEmpty else { return nil }
        for (type, candidates) in names where candidates.contains(where: { name == $0 || name.hasPrefix($0 + " ") }) {
            return type
        }
        return nil
    }

    /// - Parameter chapters: chapter names with their start times, in any order.
    public static func segments(chapters: [(name: String?, start: TimeInterval)], duration: TimeInterval) -> [MediaSegment] {
        let sorted = chapters.sorted { $0.start < $1.start }
        var result: [MediaSegment] = []
        for (index, chapter) in sorted.enumerated() {
            guard let type = type(forChapterName: chapter.name) else { continue }
            let end = index + 1 < sorted.count ? sorted[index + 1].start : duration
            guard end > chapter.start else { continue }
            result.append(MediaSegment(id: "chapter-\(index)", type: type, start: chapter.start, end: end))
        }
        return result
    }

    /// Server segments first; chapter segments only for types the server did not provide.
    public static func merge(server: [MediaSegment], chapters: [MediaSegment]) -> [MediaSegment] {
        let known = Set(server.map(\.type))
        return (server + chapters.filter { !known.contains($0.type) }).sorted { $0.start < $1.start }
    }
}
