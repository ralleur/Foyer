import Foundation
import FoyerFoundation

public struct MediaSource: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var name: String?
    public var path: String?
    public var `protocol`: MediaProtocol?
    public var container: String?
    public var size: Int64?
    public var bitrate: Int?
    public var runTimeTicks: Int64?
    public var isRemote: Bool?
    public var eTag: String?
    public var supportsDirectPlay: Bool?
    public var supportsDirectStream: Bool?
    public var supportsTranscoding: Bool?
    public var supportsProbing: Bool?
    public var isInfiniteStream: Bool?
    public var requiresOpening: Bool?
    public var openToken: String?
    public var liveStreamId: String?
    public var transcodingUrl: String?
    public var transcodingSubProtocol: String?
    public var transcodingContainer: String?
    public var defaultAudioStreamIndex: Int?
    public var defaultSubtitleStreamIndex: Int?
    public var mediaStreams: [MediaStream]?
    public var mediaAttachments: [MediaAttachment]?
    public var formats: [String]?
    public var videoType: String?
    public var hasSegments: Bool?

    public init(id: String, container: String? = nil, mediaStreams: [MediaStream]? = nil) {
        self.id = id
        self.container = container
        self.mediaStreams = mediaStreams
    }

    enum CodingKeys: String, CodingKey {
        case id = "Id"
        case name = "Name"
        case path = "Path"
        case `protocol` = "Protocol"
        case container = "Container"
        case size = "Size"
        case bitrate = "Bitrate"
        case runTimeTicks = "RunTimeTicks"
        case isRemote = "IsRemote"
        case eTag = "ETag"
        case supportsDirectPlay = "SupportsDirectPlay"
        case supportsDirectStream = "SupportsDirectStream"
        case supportsTranscoding = "SupportsTranscoding"
        case supportsProbing = "SupportsProbing"
        case isInfiniteStream = "IsInfiniteStream"
        case requiresOpening = "RequiresOpening"
        case openToken = "OpenToken"
        case liveStreamId = "LiveStreamId"
        case transcodingUrl = "TranscodingUrl"
        case transcodingSubProtocol = "TranscodingSubProtocol"
        case transcodingContainer = "TranscodingContainer"
        case defaultAudioStreamIndex = "DefaultAudioStreamIndex"
        case defaultSubtitleStreamIndex = "DefaultSubtitleStreamIndex"
        case mediaStreams = "MediaStreams"
        case mediaAttachments = "MediaAttachments"
        case formats = "Formats"
        case videoType = "VideoType"
        case hasSegments = "HasSegments"
    }

    public var streams: [MediaStream] { mediaStreams ?? [] }
    public var videoStream: MediaStream? { streams.first { $0.type == .video } }
    public var audioStreams: [MediaStream] { streams.filter { $0.type == .audio } }
    public var subtitleStreams: [MediaStream] { streams.filter { $0.type == .subtitle } }
    public var runtime: TimeInterval? { JellyfinTicks.seconds(runTimeTicks) }

    public func stream(index: Int?) -> MediaStream? {
        guard let index else { return nil }
        return streams.first { $0.index == index }
    }

    /// Lower-cased container token list. Jellyfin sometimes reports FFmpeg format
    /// names such as "mov,mp4,m4a,3gp,3g2,mj2".
    public var containerTokens: [String] {
        (container ?? "")
            .lowercased()
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    public var isHLSTranscode: Bool {
        (transcodingSubProtocol ?? "").lowercased() == "hls" || (transcodingUrl ?? "").lowercased().contains(".m3u8")
    }
}

public struct MediaAttachment: Codable, Hashable, Sendable {
    public var codec: String?
    public var codecTag: String?
    public var comment: String?
    public var index: Int?
    public var fileName: String?
    public var mimeType: String?
    public var deliveryUrl: String?

    enum CodingKeys: String, CodingKey {
        case codec = "Codec"
        case codecTag = "CodecTag"
        case comment = "Comment"
        case index = "Index"
        case fileName = "FileName"
        case mimeType = "MimeType"
        case deliveryUrl = "DeliveryUrl"
    }

    /// Fonts embedded in MKV files (needed for faithful ASS rendering).
    public var isFont: Bool {
        let mime = (mimeType ?? "").lowercased()
        let name = (fileName ?? "").lowercased()
        return mime.contains("font") || mime.contains("truetype") || mime.contains("opentype")
            || name.hasSuffix(".ttf") || name.hasSuffix(".otf") || name.hasSuffix(".ttc")
    }
}
