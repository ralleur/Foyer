import Foundation

public struct PlaybackInfoRequest: Codable, Hashable, Sendable {
    public var userId: String?
    public var mediaSourceId: String?
    public var maxStreamingBitrate: Int?
    public var startTimeTicks: Int64?
    public var audioStreamIndex: Int?
    public var subtitleStreamIndex: Int?
    public var maxAudioChannels: Int?
    public var enableDirectPlay: Bool
    public var enableDirectStream: Bool
    public var enableTranscoding: Bool
    public var allowVideoStreamCopy: Bool
    public var allowAudioStreamCopy: Bool
    public var autoOpenLiveStream: Bool
    public var alwaysBurnInSubtitleWhenTranscoding: Bool
    public var deviceProfile: DeviceProfile

    public init(userId: String?, mediaSourceId: String?, deviceProfile: DeviceProfile, maxStreamingBitrate: Int? = nil,
                startTimeTicks: Int64? = nil, audioStreamIndex: Int? = nil, subtitleStreamIndex: Int? = nil,
                enableDirectPlay: Bool = true, enableDirectStream: Bool = true, enableTranscoding: Bool = true,
                allowVideoStreamCopy: Bool = true, allowAudioStreamCopy: Bool = true) {
        self.userId = userId
        self.mediaSourceId = mediaSourceId
        self.deviceProfile = deviceProfile
        self.maxStreamingBitrate = maxStreamingBitrate
        self.startTimeTicks = startTimeTicks
        self.audioStreamIndex = audioStreamIndex
        self.subtitleStreamIndex = subtitleStreamIndex
        self.maxAudioChannels = nil
        self.enableDirectPlay = enableDirectPlay
        self.enableDirectStream = enableDirectStream
        self.enableTranscoding = enableTranscoding
        self.allowVideoStreamCopy = allowVideoStreamCopy
        self.allowAudioStreamCopy = allowAudioStreamCopy
        self.autoOpenLiveStream = true
        self.alwaysBurnInSubtitleWhenTranscoding = false
    }

    enum CodingKeys: String, CodingKey {
        case userId = "UserId"
        case mediaSourceId = "MediaSourceId"
        case maxStreamingBitrate = "MaxStreamingBitrate"
        case startTimeTicks = "StartTimeTicks"
        case audioStreamIndex = "AudioStreamIndex"
        case subtitleStreamIndex = "SubtitleStreamIndex"
        case maxAudioChannels = "MaxAudioChannels"
        case enableDirectPlay = "EnableDirectPlay"
        case enableDirectStream = "EnableDirectStream"
        case enableTranscoding = "EnableTranscoding"
        case allowVideoStreamCopy = "AllowVideoStreamCopy"
        case allowAudioStreamCopy = "AllowAudioStreamCopy"
        case autoOpenLiveStream = "AutoOpenLiveStream"
        case alwaysBurnInSubtitleWhenTranscoding = "AlwaysBurnInSubtitleWhenTranscoding"
        case deviceProfile = "DeviceProfile"
    }
}

public struct PlaybackInfoResponse: Codable, Hashable, Sendable {
    public var mediaSources: [MediaSource]
    public var playSessionId: String?
    public var errorCode: String?

    public init(mediaSources: [MediaSource], playSessionId: String?, errorCode: String? = nil) {
        self.mediaSources = mediaSources
        self.playSessionId = playSessionId
        self.errorCode = errorCode
    }

    enum CodingKeys: String, CodingKey {
        case mediaSources = "MediaSources"
        case playSessionId = "PlaySessionId"
        case errorCode = "ErrorCode"
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        mediaSources = try c.decodeIfPresent([MediaSource].self, forKey: .mediaSources) ?? []
        playSessionId = try c.decodeIfPresent(String.self, forKey: .playSessionId)
        errorCode = try c.decodeIfPresent(String.self, forKey: .errorCode)
    }
}
