import Foundation

// Jellyfin enums are modelled as "open" string wrappers instead of Swift enums so
// that values added by newer servers never break decoding.

public struct BaseItemKind: RawRepresentable, Codable, Hashable, Sendable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }

    public static let movie = BaseItemKind(rawValue: "Movie")
    public static let series = BaseItemKind(rawValue: "Series")
    public static let season = BaseItemKind(rawValue: "Season")
    public static let episode = BaseItemKind(rawValue: "Episode")
    public static let boxSet = BaseItemKind(rawValue: "BoxSet")
    public static let collectionFolder = BaseItemKind(rawValue: "CollectionFolder")
    public static let folder = BaseItemKind(rawValue: "Folder")
    public static let userView = BaseItemKind(rawValue: "UserView")
    public static let video = BaseItemKind(rawValue: "Video")
    public static let trailer = BaseItemKind(rawValue: "Trailer")
    public static let person = BaseItemKind(rawValue: "Person")
    public static let genre = BaseItemKind(rawValue: "Genre")
    public static let playlist = BaseItemKind(rawValue: "Playlist")
    public static let musicVideo = BaseItemKind(rawValue: "MusicVideo")
}

public struct MediaKind: RawRepresentable, Codable, Hashable, Sendable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public static let video = MediaKind(rawValue: "Video")
    public static let audio = MediaKind(rawValue: "Audio")
    public static let photo = MediaKind(rawValue: "Photo")
}

public struct CollectionType: RawRepresentable, Codable, Hashable, Sendable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public static let movies = CollectionType(rawValue: "movies")
    public static let tvshows = CollectionType(rawValue: "tvshows")
    public static let boxsets = CollectionType(rawValue: "boxsets")
    public static let homevideos = CollectionType(rawValue: "homevideos")
    public static let music = CollectionType(rawValue: "music")
    public static let musicvideos = CollectionType(rawValue: "musicvideos")
    public static let playlists = CollectionType(rawValue: "playlists")
    public static let photos = CollectionType(rawValue: "photos")
    public static let books = CollectionType(rawValue: "books")
    public static let livetv = CollectionType(rawValue: "livetv")
    public static let folders = CollectionType(rawValue: "folders")

    /// Libraries that make sense in a video-focused living room app.
    public var isVideoLibrary: Bool {
        switch self {
        case .movies, .tvshows, .boxsets, .homevideos, .musicvideos, .folders: true
        default: false
        }
    }
}

public struct MediaStreamKind: RawRepresentable, Codable, Hashable, Sendable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public static let video = MediaStreamKind(rawValue: "Video")
    public static let audio = MediaStreamKind(rawValue: "Audio")
    public static let subtitle = MediaStreamKind(rawValue: "Subtitle")
    public static let embeddedImage = MediaStreamKind(rawValue: "EmbeddedImage")
    public static let data = MediaStreamKind(rawValue: "Data")
    public static let lyric = MediaStreamKind(rawValue: "Lyric")
}

public struct VideoRangeType: RawRepresentable, Codable, Hashable, Sendable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public static let unknown = VideoRangeType(rawValue: "Unknown")
    public static let sdr = VideoRangeType(rawValue: "SDR")
    public static let hdr10 = VideoRangeType(rawValue: "HDR10")
    public static let hdr10Plus = VideoRangeType(rawValue: "HDR10Plus")
    public static let hlg = VideoRangeType(rawValue: "HLG")
    public static let dovi = VideoRangeType(rawValue: "DOVI")
    public static let doviWithHDR10 = VideoRangeType(rawValue: "DOVIWithHDR10")
    public static let doviWithHLG = VideoRangeType(rawValue: "DOVIWithHLG")
    public static let doviWithSDR = VideoRangeType(rawValue: "DOVIWithSDR")
    public static let doviWithEL = VideoRangeType(rawValue: "DOVIWithEL")
    public static let doviWithHDR10Plus = VideoRangeType(rawValue: "DOVIWithHDR10Plus")
    public static let doviWithELHDR10Plus = VideoRangeType(rawValue: "DOVIWithELHDR10Plus")
    public static let doviInvalid = VideoRangeType(rawValue: "DOVIInvalid")

    public var isHDR: Bool {
        switch self {
        case .sdr, .unknown, .doviWithSDR: false
        default: true
        }
    }

    public var isDolbyVision: Bool {
        rawValue.hasPrefix("DOVI")
    }

    /// True when a decoder that ignores Dolby Vision metadata still gets a correct HDR10/HLG picture.
    public var hasHDRCompatibleBaseLayer: Bool {
        switch self {
        case .hdr10, .hdr10Plus, .hlg, .doviWithHDR10, .doviWithHLG, .doviWithHDR10Plus, .doviWithEL, .doviWithELHDR10Plus: true
        default: false
        }
    }
}

public struct SubtitleDeliveryMethod: RawRepresentable, Codable, Hashable, Sendable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public static let encode = SubtitleDeliveryMethod(rawValue: "Encode")
    public static let embed = SubtitleDeliveryMethod(rawValue: "Embed")
    public static let external = SubtitleDeliveryMethod(rawValue: "External")
    public static let hls = SubtitleDeliveryMethod(rawValue: "Hls")
    public static let drop = SubtitleDeliveryMethod(rawValue: "Drop")
}

public struct PlayMethod: RawRepresentable, Codable, Hashable, Sendable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public static let directPlay = PlayMethod(rawValue: "DirectPlay")
    public static let directStream = PlayMethod(rawValue: "DirectStream")
    public static let transcode = PlayMethod(rawValue: "Transcode")
}

public struct MediaSegmentType: RawRepresentable, Codable, Hashable, Sendable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public static let unknown = MediaSegmentType(rawValue: "Unknown")
    public static let commercial = MediaSegmentType(rawValue: "Commercial")
    public static let preview = MediaSegmentType(rawValue: "Preview")
    public static let recap = MediaSegmentType(rawValue: "Recap")
    public static let outro = MediaSegmentType(rawValue: "Outro")
    public static let intro = MediaSegmentType(rawValue: "Intro")
}

public struct ImageType: RawRepresentable, Codable, Hashable, Sendable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public static let primary = ImageType(rawValue: "Primary")
    public static let backdrop = ImageType(rawValue: "Backdrop")
    public static let thumb = ImageType(rawValue: "Thumb")
    public static let logo = ImageType(rawValue: "Logo")
    public static let banner = ImageType(rawValue: "Banner")
    public static let art = ImageType(rawValue: "Art")
    public static let chapter = ImageType(rawValue: "Chapter")
}

public struct MediaProtocol: RawRepresentable, Codable, Hashable, Sendable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public static let file = MediaProtocol(rawValue: "File")
    public static let http = MediaProtocol(rawValue: "Http")
    public static let rtmp = MediaProtocol(rawValue: "Rtmp")
    public static let rtsp = MediaProtocol(rawValue: "Rtsp")
    public static let udp = MediaProtocol(rawValue: "Udp")
    public static let rtp = MediaProtocol(rawValue: "Rtp")
    public static let ftp = MediaProtocol(rawValue: "Ftp")
}

public struct LocationType: RawRepresentable, Codable, Hashable, Sendable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public static let fileSystem = LocationType(rawValue: "FileSystem")
    public static let remote = LocationType(rawValue: "Remote")
    public static let virtual = LocationType(rawValue: "Virtual")
    public static let offline = LocationType(rawValue: "Offline")
}

public struct ItemSortBy: RawRepresentable, Codable, Hashable, Sendable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public static let sortName = ItemSortBy(rawValue: "SortName")
    public static let dateCreated = ItemSortBy(rawValue: "DateCreated")
    public static let datePlayed = ItemSortBy(rawValue: "DatePlayed")
    public static let premiereDate = ItemSortBy(rawValue: "PremiereDate")
    public static let productionYear = ItemSortBy(rawValue: "ProductionYear")
    public static let communityRating = ItemSortBy(rawValue: "CommunityRating")
    public static let criticRating = ItemSortBy(rawValue: "CriticRating")
    public static let runtime = ItemSortBy(rawValue: "Runtime")
    public static let random = ItemSortBy(rawValue: "Random")
    public static let dateLastContentAdded = ItemSortBy(rawValue: "DateLastContentAdded")
    public static let seriesSortName = ItemSortBy(rawValue: "SeriesSortName")
    public static let parentIndexNumber = ItemSortBy(rawValue: "ParentIndexNumber")
    public static let indexNumber = ItemSortBy(rawValue: "IndexNumber")
}

public enum SortOrder: String, Codable, Sendable {
    case ascending = "Ascending"
    case descending = "Descending"
}

public struct ItemFilter: RawRepresentable, Codable, Hashable, Sendable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public static let isUnplayed = ItemFilter(rawValue: "IsUnplayed")
    public static let isPlayed = ItemFilter(rawValue: "IsPlayed")
    public static let isFavorite = ItemFilter(rawValue: "IsFavorite")
    public static let isResumable = ItemFilter(rawValue: "IsResumable")
    public static let isNotFolder = ItemFilter(rawValue: "IsNotFolder")
}

public struct ItemField: RawRepresentable, Codable, Hashable, Sendable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public static let overview = ItemField(rawValue: "Overview")
    public static let genres = ItemField(rawValue: "Genres")
    public static let people = ItemField(rawValue: "People")
    public static let studios = ItemField(rawValue: "Studios")
    public static let taglines = ItemField(rawValue: "Taglines")
    public static let mediaSources = ItemField(rawValue: "MediaSources")
    public static let mediaStreams = ItemField(rawValue: "MediaStreams")
    public static let chapters = ItemField(rawValue: "Chapters")
    public static let trickplay = ItemField(rawValue: "Trickplay")
    public static let childCount = ItemField(rawValue: "ChildCount")
    public static let recursiveItemCount = ItemField(rawValue: "RecursiveItemCount")
    public static let primaryImageAspectRatio = ItemField(rawValue: "PrimaryImageAspectRatio")
    public static let dateCreated = ItemField(rawValue: "DateCreated")
    public static let etag = ItemField(rawValue: "Etag")
    public static let originalTitle = ItemField(rawValue: "OriginalTitle")
    public static let path = ItemField(rawValue: "Path")
    public static let parentId = ItemField(rawValue: "ParentId")
    public static let seasonUserData = ItemField(rawValue: "SeasonUserData")
    public static let mediaSourceCount = ItemField(rawValue: "MediaSourceCount")
    public static let specialEpisodeNumbers = ItemField(rawValue: "SpecialEpisodeNumbers")
    public static let externalUrls = ItemField(rawValue: "ExternalUrls")

    /// Fields needed to render cards in rows and grids.
    public static let card: [ItemField] = [.primaryImageAspectRatio, .childCount, .recursiveItemCount, .mediaSourceCount]
    /// Fields for detail screens.
    public static let detail: [ItemField] = [
        .overview, .genres, .people, .studios, .taglines, .mediaSources, .mediaStreams, .chapters, .trickplay,
        .childCount, .recursiveItemCount, .primaryImageAspectRatio, .dateCreated, .etag, .originalTitle, .mediaSourceCount,
        .externalUrls,
    ]
}
