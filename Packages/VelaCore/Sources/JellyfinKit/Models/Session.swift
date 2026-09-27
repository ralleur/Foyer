import Foundation

/// Body for `/Sessions/Playing` and `/Sessions/Playing/Progress`.
public struct PlaybackStateReport: Codable, Hashable, Sendable {
    public var itemId: String
    public var mediaSourceId: String?
    public var playSessionId: String?
    public var positionTicks: Int64
    public var isPaused: Bool
    public var isMuted: Bool
    public var canSeek: Bool
    public var playMethod: PlayMethod
    public var audioStreamIndex: Int?
    public var subtitleStreamIndex: Int?
    public var volumeLevel: Int
    public var repeatMode: String
    public var playbackOrder: String
    public var eventName: String?

    public init(itemId: String, mediaSourceId: String?, playSessionId: String?, positionTicks: Int64, isPaused: Bool,
                playMethod: PlayMethod, audioStreamIndex: Int?, subtitleStreamIndex: Int?, eventName: String? = nil) {
        self.itemId = itemId
        self.mediaSourceId = mediaSourceId
        self.playSessionId = playSessionId
        self.positionTicks = positionTicks
        self.isPaused = isPaused
        self.isMuted = false
        self.canSeek = true
        self.playMethod = playMethod
        self.audioStreamIndex = audioStreamIndex
        self.subtitleStreamIndex = subtitleStreamIndex
        self.volumeLevel = 100
        self.repeatMode = "RepeatNone"
        self.playbackOrder = "Default"
        self.eventName = eventName
    }

    enum CodingKeys: String, CodingKey {
        case itemId = "ItemId"
        case mediaSourceId = "MediaSourceId"
        case playSessionId = "PlaySessionId"
        case positionTicks = "PositionTicks"
        case isPaused = "IsPaused"
        case isMuted = "IsMuted"
        case canSeek = "CanSeek"
        case playMethod = "PlayMethod"
        case audioStreamIndex = "AudioStreamIndex"
        case subtitleStreamIndex = "SubtitleStreamIndex"
        case volumeLevel = "VolumeLevel"
        case repeatMode = "RepeatMode"
        case playbackOrder = "PlaybackOrder"
        case eventName = "EventName"
    }
}

/// Body for `/Sessions/Playing/Stopped`.
public struct PlaybackStopReport: Codable, Hashable, Sendable {
    public var itemId: String
    public var mediaSourceId: String?
    public var playSessionId: String?
    public var positionTicks: Int64
    public var failed: Bool

    public init(itemId: String, mediaSourceId: String?, playSessionId: String?, positionTicks: Int64, failed: Bool = false) {
        self.itemId = itemId
        self.mediaSourceId = mediaSourceId
        self.playSessionId = playSessionId
        self.positionTicks = positionTicks
        self.failed = failed
    }

    enum CodingKeys: String, CodingKey {
        case itemId = "ItemId"
        case mediaSourceId = "MediaSourceId"
        case playSessionId = "PlaySessionId"
        case positionTicks = "PositionTicks"
        case failed = "Failed"
    }
}

/// Body for `/Sessions/Capabilities/Full`.
public struct ClientCapabilities: Codable, Hashable, Sendable {
    public var playableMediaTypes: [String]
    public var supportedCommands: [String]
    public var supportsMediaControl: Bool
    public var supportsPersistentIdentifier: Bool
    public var deviceProfile: DeviceProfile?

    public init(playableMediaTypes: [String] = ["Video"],
                supportedCommands: [String] = ["Play", "PlayState", "DisplayMessage", "SetAudioStreamIndex", "SetSubtitleStreamIndex"],
                supportsMediaControl: Bool = true, supportsPersistentIdentifier: Bool = true, deviceProfile: DeviceProfile? = nil) {
        self.playableMediaTypes = playableMediaTypes
        self.supportedCommands = supportedCommands
        self.supportsMediaControl = supportsMediaControl
        self.supportsPersistentIdentifier = supportsPersistentIdentifier
        self.deviceProfile = deviceProfile
    }

    enum CodingKeys: String, CodingKey {
        case playableMediaTypes = "PlayableMediaTypes"
        case supportedCommands = "SupportedCommands"
        case supportsMediaControl = "SupportsMediaControl"
        case supportsPersistentIdentifier = "SupportsPersistentIdentifier"
        case deviceProfile = "DeviceProfile"
    }
}
