import Foundation

// Jellyfin device profile. Sent with PlaybackInfo so the server can decide
// between direct play, direct stream (remux) and transcoding.

public struct DeviceProfile: Codable, Hashable, Sendable {
    public var name: String?
    public var maxStreamingBitrate: Int?
    public var maxStaticBitrate: Int?
    public var musicStreamingTranscodingBitrate: Int?
    public var directPlayProfiles: [DirectPlayProfile]
    public var transcodingProfiles: [TranscodingProfile]
    public var containerProfiles: [ContainerProfile]
    public var codecProfiles: [CodecProfile]
    public var subtitleProfiles: [SubtitleProfile]

    public init(name: String? = nil, maxStreamingBitrate: Int? = nil, maxStaticBitrate: Int? = nil,
                directPlayProfiles: [DirectPlayProfile] = [], transcodingProfiles: [TranscodingProfile] = [],
                containerProfiles: [ContainerProfile] = [], codecProfiles: [CodecProfile] = [],
                subtitleProfiles: [SubtitleProfile] = []) {
        self.name = name
        self.maxStreamingBitrate = maxStreamingBitrate
        self.maxStaticBitrate = maxStaticBitrate
        self.musicStreamingTranscodingBitrate = nil
        self.directPlayProfiles = directPlayProfiles
        self.transcodingProfiles = transcodingProfiles
        self.containerProfiles = containerProfiles
        self.codecProfiles = codecProfiles
        self.subtitleProfiles = subtitleProfiles
    }

    enum CodingKeys: String, CodingKey {
        case name = "Name"
        case maxStreamingBitrate = "MaxStreamingBitrate"
        case maxStaticBitrate = "MaxStaticBitrate"
        case musicStreamingTranscodingBitrate = "MusicStreamingTranscodingBitrate"
        case directPlayProfiles = "DirectPlayProfiles"
        case transcodingProfiles = "TranscodingProfiles"
        case containerProfiles = "ContainerProfiles"
        case codecProfiles = "CodecProfiles"
        case subtitleProfiles = "SubtitleProfiles"
    }
}

public enum DlnaProfileType: String, Codable, Sendable {
    case audio = "Audio"
    case video = "Video"
    case photo = "Photo"
    case subtitle = "Subtitle"
}

public struct DirectPlayProfile: Codable, Hashable, Sendable {
    public var container: String
    public var audioCodec: String?
    public var videoCodec: String?
    public var type: DlnaProfileType

    public init(container: String, audioCodec: String? = nil, videoCodec: String? = nil, type: DlnaProfileType = .video) {
        self.container = container
        self.audioCodec = audioCodec
        self.videoCodec = videoCodec
        self.type = type
    }

    enum CodingKeys: String, CodingKey {
        case container = "Container"
        case audioCodec = "AudioCodec"
        case videoCodec = "VideoCodec"
        case type = "Type"
    }
}

public enum EncodingContext: String, Codable, Sendable {
    case streaming = "Streaming"
    case `static` = "Static"
}

public struct TranscodingProfile: Codable, Hashable, Sendable {
    public var container: String
    public var type: DlnaProfileType
    public var videoCodec: String?
    public var audioCodec: String?
    public var `protocol`: String
    public var context: EncodingContext
    public var maxAudioChannels: String?
    public var minSegments: Int?
    public var segmentLength: Int?
    public var breakOnNonKeyFrames: Bool
    public var copyTimestamps: Bool
    public var enableSubtitlesInManifest: Bool
    public var enableMpegtsM2TsMode: Bool
    public var estimateContentLength: Bool
    public var conditions: [ProfileCondition]

    public init(container: String, type: DlnaProfileType = .video, videoCodec: String?, audioCodec: String?,
                protocol: String = "hls", context: EncodingContext = .streaming, maxAudioChannels: String? = "8",
                minSegments: Int? = 2, segmentLength: Int? = nil, breakOnNonKeyFrames: Bool = true,
                copyTimestamps: Bool = false, enableSubtitlesInManifest: Bool = false,
                conditions: [ProfileCondition] = []) {
        self.container = container
        self.type = type
        self.videoCodec = videoCodec
        self.audioCodec = audioCodec
        self.protocol = `protocol`
        self.context = context
        self.maxAudioChannels = maxAudioChannels
        self.minSegments = minSegments
        self.segmentLength = segmentLength
        self.breakOnNonKeyFrames = breakOnNonKeyFrames
        self.copyTimestamps = copyTimestamps
        self.enableSubtitlesInManifest = enableSubtitlesInManifest
        self.enableMpegtsM2TsMode = false
        self.estimateContentLength = false
        self.conditions = conditions
    }

    enum CodingKeys: String, CodingKey {
        case container = "Container"
        case type = "Type"
        case videoCodec = "VideoCodec"
        case audioCodec = "AudioCodec"
        case `protocol` = "Protocol"
        case context = "Context"
        case maxAudioChannels = "MaxAudioChannels"
        case minSegments = "MinSegments"
        case segmentLength = "SegmentLength"
        case breakOnNonKeyFrames = "BreakOnNonKeyFrames"
        case copyTimestamps = "CopyTimestamps"
        case enableSubtitlesInManifest = "EnableSubtitlesInManifest"
        case enableMpegtsM2TsMode = "EnableMpegtsM2TsMode"
        case estimateContentLength = "EstimateContentLength"
        case conditions = "Conditions"
    }
}

public struct ContainerProfile: Codable, Hashable, Sendable {
    public var type: DlnaProfileType
    public var container: String?
    public var conditions: [ProfileCondition]

    public init(type: DlnaProfileType = .video, container: String? = nil, conditions: [ProfileCondition] = []) {
        self.type = type
        self.container = container
        self.conditions = conditions
    }

    enum CodingKeys: String, CodingKey {
        case type = "Type"
        case container = "Container"
        case conditions = "Conditions"
    }
}

public enum CodecProfileType: String, Codable, Sendable {
    case video = "Video"
    case videoAudio = "VideoAudio"
    case audio = "Audio"
}

public struct CodecProfile: Codable, Hashable, Sendable {
    public var type: CodecProfileType
    public var codec: String?
    public var container: String?
    public var conditions: [ProfileCondition]
    public var applyConditions: [ProfileCondition]

    public init(type: CodecProfileType, codec: String?, container: String? = nil,
                conditions: [ProfileCondition], applyConditions: [ProfileCondition] = []) {
        self.type = type
        self.codec = codec
        self.container = container
        self.conditions = conditions
        self.applyConditions = applyConditions
    }

    enum CodingKeys: String, CodingKey {
        case type = "Type"
        case codec = "Codec"
        case container = "Container"
        case conditions = "Conditions"
        case applyConditions = "ApplyConditions"
    }
}

public enum ProfileConditionType: String, Codable, Sendable {
    case equals = "Equals"
    case notEquals = "NotEquals"
    case lessThanEqual = "LessThanEqual"
    case greaterThanEqual = "GreaterThanEqual"
    case equalsAny = "EqualsAny"
}

public enum ProfileConditionValue: String, Codable, Sendable {
    case audioChannels = "AudioChannels"
    case audioBitrate = "AudioBitrate"
    case audioProfile = "AudioProfile"
    case audioSampleRate = "AudioSampleRate"
    case audioBitDepth = "AudioBitDepth"
    case width = "Width"
    case height = "Height"
    case videoBitDepth = "VideoBitDepth"
    case videoBitrate = "VideoBitrate"
    case videoFramerate = "VideoFramerate"
    case videoLevel = "VideoLevel"
    case videoProfile = "VideoProfile"
    case videoRangeType = "VideoRangeType"
    case videoCodecTag = "VideoCodecTag"
    case isAnamorphic = "IsAnamorphic"
    case isInterlaced = "IsInterlaced"
    case isSecondaryAudio = "IsSecondaryAudio"
    case numAudioStreams = "NumAudioStreams"
    case numVideoStreams = "NumVideoStreams"
    case refFrames = "RefFrames"
    case isAvc = "IsAvc"
    case videoRotation = "VideoRotation"
}

public struct ProfileCondition: Codable, Hashable, Sendable {
    public var condition: ProfileConditionType
    public var property: ProfileConditionValue
    public var value: String
    public var isRequired: Bool

    public init(_ property: ProfileConditionValue, _ condition: ProfileConditionType, _ value: String, isRequired: Bool = false) {
        self.condition = condition
        self.property = property
        self.value = value
        self.isRequired = isRequired
    }

    enum CodingKeys: String, CodingKey {
        case condition = "Condition"
        case property = "Property"
        case value = "Value"
        case isRequired = "IsRequired"
    }
}

public struct SubtitleProfile: Codable, Hashable, Sendable {
    public var format: String
    public var method: SubtitleDeliveryMethod
    public var container: String?
    public var language: String?

    public init(format: String, method: SubtitleDeliveryMethod, container: String? = nil) {
        self.format = format
        self.method = method
        self.container = container
        self.language = nil
    }

    enum CodingKeys: String, CodingKey {
        case format = "Format"
        case method = "Method"
        case container = "Container"
        case language = "Language"
    }
}
