import Foundation
import VelaFoundation

/// Jellyfin `BaseItemDto`, reduced to what a video client needs. All fields are optional
/// because the server omits anything that is not set or not requested via `fields`.
public struct BaseItem: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var name: String?
    public var originalTitle: String?
    public var sortName: String?
    public var serverId: String?
    public var etag: String?
    public var type: BaseItemKind?
    public var mediaType: MediaKind?
    public var collectionType: CollectionType?
    public var locationType: LocationType?
    public var isFolder: Bool?
    public var parentId: String?
    public var overview: String?
    public var taglines: [String]?
    public var genres: [String]?
    public var tags: [String]?
    public var studios: [NameIdPair]?
    public var people: [Person]?
    public var productionYear: Int?
    public var premiereDate: Date?
    public var endDate: Date?
    public var dateCreated: Date?
    public var status: String?
    public var runTimeTicks: Int64?
    public var cumulativeRunTimeTicks: Int64?
    public var officialRating: String?
    public var communityRating: Double?
    public var criticRating: Double?
    public var userData: UserData?
    public var imageTags: [String: String]?
    public var backdropImageTags: [String]?
    public var primaryImageAspectRatio: Double?
    public var parentBackdropItemId: String?
    public var parentBackdropImageTags: [String]?
    public var parentThumbItemId: String?
    public var parentThumbImageTag: String?
    public var parentPrimaryImageItemId: String?
    public var parentPrimaryImageTag: String?
    public var parentLogoItemId: String?
    public var parentLogoImageTag: String?
    public var seriesId: String?
    public var seriesName: String?
    public var seriesPrimaryImageTag: String?
    public var seriesThumbImageTag: String?
    public var seasonId: String?
    public var seasonName: String?
    public var indexNumber: Int?
    public var indexNumberEnd: Int?
    public var parentIndexNumber: Int?
    public var childCount: Int?
    public var recursiveItemCount: Int?
    public var episodeCount: Int?
    public var mediaSourceCount: Int?
    public var partCount: Int?
    public var container: String?
    public var width: Int?
    public var height: Int?
    public var hasSubtitles: Bool?
    public var mediaSources: [MediaSource]?
    public var mediaStreams: [MediaStream]?
    public var chapters: [Chapter]?
    /// Keyed by media source id, then by tile width.
    public var trickplay: [String: [String: TrickplayInfo]]?
    public var path: String?
    public var externalUrls: [ExternalURL]?

    public init(id: String, name: String? = nil, type: BaseItemKind? = nil) {
        self.id = id
        self.name = name
        self.type = type
    }

    enum CodingKeys: String, CodingKey {
        case id = "Id"
        case name = "Name"
        case originalTitle = "OriginalTitle"
        case sortName = "SortName"
        case serverId = "ServerId"
        case etag = "Etag"
        case type = "Type"
        case mediaType = "MediaType"
        case collectionType = "CollectionType"
        case locationType = "LocationType"
        case isFolder = "IsFolder"
        case parentId = "ParentId"
        case overview = "Overview"
        case taglines = "Taglines"
        case genres = "Genres"
        case tags = "Tags"
        case studios = "Studios"
        case people = "People"
        case productionYear = "ProductionYear"
        case premiereDate = "PremiereDate"
        case endDate = "EndDate"
        case dateCreated = "DateCreated"
        case status = "Status"
        case runTimeTicks = "RunTimeTicks"
        case cumulativeRunTimeTicks = "CumulativeRunTimeTicks"
        case officialRating = "OfficialRating"
        case communityRating = "CommunityRating"
        case criticRating = "CriticRating"
        case userData = "UserData"
        case imageTags = "ImageTags"
        case backdropImageTags = "BackdropImageTags"
        case primaryImageAspectRatio = "PrimaryImageAspectRatio"
        case parentBackdropItemId = "ParentBackdropItemId"
        case parentBackdropImageTags = "ParentBackdropImageTags"
        case parentThumbItemId = "ParentThumbItemId"
        case parentThumbImageTag = "ParentThumbImageTag"
        case parentPrimaryImageItemId = "ParentPrimaryImageItemId"
        case parentPrimaryImageTag = "ParentPrimaryImageTag"
        case parentLogoItemId = "ParentLogoItemId"
        case parentLogoImageTag = "ParentLogoImageTag"
        case seriesId = "SeriesId"
        case seriesName = "SeriesName"
        case seriesPrimaryImageTag = "SeriesPrimaryImageTag"
        case seriesThumbImageTag = "SeriesThumbImageTag"
        case seasonId = "SeasonId"
        case seasonName = "SeasonName"
        case indexNumber = "IndexNumber"
        case indexNumberEnd = "IndexNumberEnd"
        case parentIndexNumber = "ParentIndexNumber"
        case childCount = "ChildCount"
        case recursiveItemCount = "RecursiveItemCount"
        case episodeCount = "EpisodeCount"
        case mediaSourceCount = "MediaSourceCount"
        case partCount = "PartCount"
        case container = "Container"
        case width = "Width"
        case height = "Height"
        case hasSubtitles = "HasSubtitles"
        case mediaSources = "MediaSources"
        case mediaStreams = "MediaStreams"
        case chapters = "Chapters"
        case trickplay = "Trickplay"
        case path = "Path"
        case externalUrls = "ExternalUrls"
    }

    // MARK: Derived helpers

    public var runtime: TimeInterval? { JellyfinTicks.seconds(runTimeTicks) }

    public var isMovie: Bool { type == .movie }
    public var isSeries: Bool { type == .series }
    public var isSeason: Bool { type == .season }
    public var isEpisode: Bool { type == .episode }
    public var isCollection: Bool { type == .boxSet }
    public var isPlayable: Bool {
        guard mediaType == .video || type == .movie || type == .episode || type == .video || type == .trailer || type == .musicVideo else {
            return false
        }
        return isFolder != true
    }

    public var displayTitle: String { name ?? originalTitle ?? "" }

    /// "S2 · E5" style label for episodes.
    public var episodeLabel: String? {
        guard isEpisode else { return nil }
        let season = parentIndexNumber
        let episode = indexNumber
        switch (season, episode) {
        case let (s?, e?):
            if let end = indexNumberEnd, end != e { return "S\(s) · E\(e)–\(end)" }
            return "S\(s) · E\(e)"
        case let (nil, e?):
            return "E\(e)"
        default:
            return nil
        }
    }

    public var playedPercentage: Double? {
        if let p = userData?.playedPercentage, p > 0 { return min(max(p, 0), 100) }
        if let ticks = userData?.playbackPositionTicks, ticks > 0, let total = runTimeTicks, total > 0 {
            return Double(ticks) / Double(total) * 100
        }
        return nil
    }

    public var resumePosition: TimeInterval? {
        guard let ticks = userData?.playbackPositionTicks, ticks > 0 else { return nil }
        return JellyfinTicks.seconds(ticks)
    }

    public var isPlayed: Bool { userData?.played == true }
    public var isFavorite: Bool { userData?.isFavorite == true }

    public var primaryImageTag: String? { imageTags?["Primary"] }
    public var logoImageTag: String? { imageTags?["Logo"] }
    public var thumbImageTag: String? { imageTags?["Thumb"] }
    public var firstBackdropTag: String? { backdropImageTags?.first }

    public var defaultMediaSource: MediaSource? { mediaSources?.first }

    public func mediaSource(id: String?) -> MediaSource? {
        guard let id else { return defaultMediaSource }
        return mediaSources?.first { $0.id == id } ?? defaultMediaSource
    }
}

public struct NameIdPair: Codable, Hashable, Sendable {
    public var id: String?
    public var name: String?

    public init(id: String? = nil, name: String? = nil) {
        self.id = id
        self.name = name
    }

    enum CodingKeys: String, CodingKey {
        case id = "Id"
        case name = "Name"
    }
}

public struct Person: Codable, Hashable, Sendable, Identifiable {
    public var id: String?
    public var name: String?
    public var role: String?
    public var type: String?
    public var primaryImageTag: String?

    public init(id: String? = nil, name: String? = nil, role: String? = nil, type: String? = nil, primaryImageTag: String? = nil) {
        self.id = id
        self.name = name
        self.role = role
        self.type = type
        self.primaryImageTag = primaryImageTag
    }

    enum CodingKeys: String, CodingKey {
        case id = "Id"
        case name = "Name"
        case role = "Role"
        case type = "Type"
        case primaryImageTag = "PrimaryImageTag"
    }
}

public struct ExternalURL: Codable, Hashable, Sendable {
    public var name: String?
    public var url: String?

    enum CodingKeys: String, CodingKey {
        case name = "Name"
        case url = "Url"
    }
}

public struct UserData: Codable, Hashable, Sendable {
    public var playbackPositionTicks: Int64?
    public var playCount: Int?
    public var isFavorite: Bool?
    public var played: Bool?
    public var playedPercentage: Double?
    public var unplayedItemCount: Int?
    public var lastPlayedDate: Date?
    public var itemId: String?
    public var key: String?

    public init(playbackPositionTicks: Int64? = nil, playCount: Int? = nil, isFavorite: Bool? = nil, played: Bool? = nil,
                playedPercentage: Double? = nil, unplayedItemCount: Int? = nil, lastPlayedDate: Date? = nil) {
        self.playbackPositionTicks = playbackPositionTicks
        self.playCount = playCount
        self.isFavorite = isFavorite
        self.played = played
        self.playedPercentage = playedPercentage
        self.unplayedItemCount = unplayedItemCount
        self.lastPlayedDate = lastPlayedDate
    }

    enum CodingKeys: String, CodingKey {
        case playbackPositionTicks = "PlaybackPositionTicks"
        case playCount = "PlayCount"
        case isFavorite = "IsFavorite"
        case played = "Played"
        case playedPercentage = "PlayedPercentage"
        case unplayedItemCount = "UnplayedItemCount"
        case lastPlayedDate = "LastPlayedDate"
        case itemId = "ItemId"
        case key = "Key"
    }
}

public struct Chapter: Codable, Hashable, Sendable {
    public var startPositionTicks: Int64?
    public var name: String?
    public var imageTag: String?

    public init(startPositionTicks: Int64? = nil, name: String? = nil, imageTag: String? = nil) {
        self.startPositionTicks = startPositionTicks
        self.name = name
        self.imageTag = imageTag
    }

    enum CodingKeys: String, CodingKey {
        case startPositionTicks = "StartPositionTicks"
        case name = "Name"
        case imageTag = "ImageTag"
    }

    public var start: TimeInterval { JellyfinTicks.seconds(startPositionTicks ?? 0) }
}

public struct TrickplayInfo: Codable, Hashable, Sendable {
    public var width: Int
    public var height: Int
    public var tileWidth: Int
    public var tileHeight: Int
    public var thumbnailCount: Int
    /// Interval between thumbnails in milliseconds.
    public var interval: Int
    public var bandwidth: Int?

    public init(width: Int, height: Int, tileWidth: Int, tileHeight: Int, thumbnailCount: Int, interval: Int, bandwidth: Int? = nil) {
        self.width = width
        self.height = height
        self.tileWidth = tileWidth
        self.tileHeight = tileHeight
        self.thumbnailCount = thumbnailCount
        self.interval = interval
        self.bandwidth = bandwidth
    }

    enum CodingKeys: String, CodingKey {
        case width = "Width"
        case height = "Height"
        case tileWidth = "TileWidth"
        case tileHeight = "TileHeight"
        case thumbnailCount = "ThumbnailCount"
        case interval = "Interval"
        case bandwidth = "Bandwidth"
    }
}

public struct QueryResult<Item: Codable & Sendable & Hashable>: Codable, Sendable, Hashable {
    public var items: [Item]
    public var totalRecordCount: Int?
    public var startIndex: Int?

    public init(items: [Item], totalRecordCount: Int? = nil, startIndex: Int? = nil) {
        self.items = items
        self.totalRecordCount = totalRecordCount
        self.startIndex = startIndex
    }

    enum CodingKeys: String, CodingKey {
        case items = "Items"
        case totalRecordCount = "TotalRecordCount"
        case startIndex = "StartIndex"
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        items = try container.decodeIfPresent([Item].self, forKey: .items) ?? []
        totalRecordCount = try container.decodeIfPresent(Int.self, forKey: .totalRecordCount)
        startIndex = try container.decodeIfPresent(Int.self, forKey: .startIndex)
    }
}
