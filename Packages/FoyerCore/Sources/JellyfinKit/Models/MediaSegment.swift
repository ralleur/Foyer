import Foundation
import FoyerFoundation

/// Jellyfin 10.10+ media segment (intro, outro, recap, preview, commercial).
public struct MediaSegment: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var itemId: String?
    public var type: MediaSegmentType
    public var startTicks: Int64
    public var endTicks: Int64

    public init(id: String = UUID().uuidString, itemId: String? = nil, type: MediaSegmentType, startTicks: Int64, endTicks: Int64) {
        self.id = id
        self.itemId = itemId
        self.type = type
        self.startTicks = startTicks
        self.endTicks = endTicks
    }

    public init(id: String = UUID().uuidString, type: MediaSegmentType, start: TimeInterval, end: TimeInterval) {
        self.init(id: id, type: type, startTicks: JellyfinTicks.ticks(seconds: start), endTicks: JellyfinTicks.ticks(seconds: end))
    }

    enum CodingKeys: String, CodingKey {
        case id = "Id"
        case itemId = "ItemId"
        case type = "Type"
        case startTicks = "StartTicks"
        case endTicks = "EndTicks"
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        itemId = try c.decodeIfPresent(String.self, forKey: .itemId)
        type = try c.decodeIfPresent(MediaSegmentType.self, forKey: .type) ?? .unknown
        startTicks = try c.decodeIfPresent(Int64.self, forKey: .startTicks) ?? 0
        endTicks = try c.decodeIfPresent(Int64.self, forKey: .endTicks) ?? 0
    }

    public var start: TimeInterval { JellyfinTicks.seconds(startTicks) }
    public var end: TimeInterval { JellyfinTicks.seconds(endTicks) }
    public var duration: TimeInterval { max(0, end - start) }

    public func contains(_ time: TimeInterval) -> Bool {
        time >= start && time < end
    }
}

/// Response of the Intro Skipper plugin (`/Episode/{id}/IntroTimestamps/v1`).
public struct IntroSkipperTimestamps: Codable, Hashable, Sendable {
    public var valid: Bool?
    public var introStart: Double?
    public var introEnd: Double?
    public var showSkipPromptAt: Double?
    public var hideSkipPromptAt: Double?

    enum CodingKeys: String, CodingKey {
        case valid = "Valid"
        case introStart = "IntroStart"
        case introEnd = "IntroEnd"
        case showSkipPromptAt = "ShowSkipPromptAt"
        case hideSkipPromptAt = "HideSkipPromptAt"
    }

    public func asSegment(type: MediaSegmentType) -> MediaSegment? {
        guard valid != false, let s = introStart, let e = introEnd, e > s, e - s >= 1 else { return nil }
        return MediaSegment(type: type, start: s, end: e)
    }
}

/// Response of the newer Intro Skipper endpoint (`/Episode/{id}/IntroSkipperSegments`).
public struct IntroSkipperSegments: Codable, Hashable, Sendable {
    public var introduction: IntroSkipperTimestamps?
    public var credits: IntroSkipperTimestamps?

    enum CodingKeys: String, CodingKey {
        case introduction = "Introduction"
        case credits = "Credits"
    }

    public var segments: [MediaSegment] {
        [introduction?.asSegment(type: .intro), credits?.asSegment(type: .outro)].compactMap { $0 }
    }
}
