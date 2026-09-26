import Foundation

/// What this Apple TV and its connected display/audio chain can do.
/// Values are detected at runtime by the app (VideoToolbox, AVPlayer HDR modes,
/// AVAudioSession) and passed into the decision engine; the defaults describe
/// an Apple TV 4K connected to an HDR television.
public struct DeviceCapabilities: Sendable, Hashable, Codable {
    public var modelName: String
    public var supportsHEVCHardware: Bool
    public var supportsHEVC10Bit: Bool
    public var supportsAV1Hardware: Bool
    public var supportsHDR10: Bool
    public var supportsHLG: Bool
    public var supportsDolbyVision: Bool
    public var maxVideoWidth: Int
    public var maxVideoHeight: Int
    public var maxFrameRate: Double
    /// Channels the audio output path accepts (2 for TV speakers/stereo, 6/8 for receivers).
    public var maxOutputChannels: Int
    /// AC-3 / E-AC-3 (incl. Atmos JOC) can be passed through to the receiver by the system player.
    public var supportsDolbyPassthrough: Bool
    /// The mpv based engine is linked into this build.
    public var advancedEngineAvailable: Bool
    /// The advanced engine can present true HDR (not the case on tvOS: no EDR Metal layer).
    public var advancedEngineSupportsHDROutput: Bool
    /// Maximum height the advanced engine decodes in software with headroom (AV1/VP9 without hardware).
    public var advancedEngineMaxSoftwareDecodeHeight: Int

    public init(modelName: String = "Apple TV 4K", supportsHEVCHardware: Bool = true, supportsHEVC10Bit: Bool = true,
                supportsAV1Hardware: Bool = false, supportsHDR10: Bool = true, supportsHLG: Bool = true,
                supportsDolbyVision: Bool = true, maxVideoWidth: Int = 3840, maxVideoHeight: Int = 2160,
                maxFrameRate: Double = 60, maxOutputChannels: Int = 8, supportsDolbyPassthrough: Bool = true,
                advancedEngineAvailable: Bool = true, advancedEngineSupportsHDROutput: Bool = false,
                advancedEngineMaxSoftwareDecodeHeight: Int = 1080) {
        self.modelName = modelName
        self.supportsHEVCHardware = supportsHEVCHardware
        self.supportsHEVC10Bit = supportsHEVC10Bit
        self.supportsAV1Hardware = supportsAV1Hardware
        self.supportsHDR10 = supportsHDR10
        self.supportsHLG = supportsHLG
        self.supportsDolbyVision = supportsDolbyVision
        self.maxVideoWidth = maxVideoWidth
        self.maxVideoHeight = maxVideoHeight
        self.maxFrameRate = maxFrameRate
        self.maxOutputChannels = maxOutputChannels
        self.supportsDolbyPassthrough = supportsDolbyPassthrough
        self.advancedEngineAvailable = advancedEngineAvailable
        self.advancedEngineSupportsHDROutput = advancedEngineSupportsHDROutput
        self.advancedEngineMaxSoftwareDecodeHeight = advancedEngineMaxSoftwareDecodeHeight
    }

    /// Apple TV 4K (any generation) on an HDR/Dolby Vision display.
    public static let appleTV4KHDR = DeviceCapabilities()

    /// Apple TV 4K on an SDR-only display (HDR would be tone-mapped by the box, so we avoid claiming it).
    public static let appleTV4KSDR = DeviceCapabilities(supportsHDR10: false, supportsHLG: false, supportsDolbyVision: false)

    /// Apple TV HD (A8): 1080p, HEVC 8-bit only, no HDR.
    public static let appleTVHD = DeviceCapabilities(modelName: "Apple TV HD", supportsHEVCHardware: true, supportsHEVC10Bit: false,
                                                      supportsHDR10: false, supportsHLG: false, supportsDolbyVision: false,
                                                      maxVideoWidth: 1920, maxVideoHeight: 1080,
                                                      advancedEngineMaxSoftwareDecodeHeight: 720)

    public var supportsAnyHDR: Bool { supportsHDR10 || supportsHLG || supportsDolbyVision }
}

public enum DirectPlayMode: String, Sendable, Codable, CaseIterable, Hashable {
    /// Direct play whenever a local engine can handle the file (default).
    case preferred
    /// Never ask the server to remux or transcode; fail instead.
    case forced
    /// Send a conservative profile and let the server decide.
    case serverDecides
}

public enum AdvancedEngineMode: String, Sendable, Codable, CaseIterable, Hashable {
    case automatic
    case always
    case never
}

public struct PlaybackPreferences: Sendable, Hashable, Codable {
    public var directPlayMode: DirectPlayMode
    public var advancedEngineMode: AdvancedEngineMode
    /// Bits per second; nil means unlimited (original quality).
    public var maxStreamingBitrate: Int?
    /// Keep real HDR output via the system player (server remux) instead of tone-mapping in the advanced engine.
    public var preferHDRPicture: Bool
    /// Allow the server to burn bitmap subtitles into the picture as a last resort.
    public var allowBurnInSubtitles: Bool

    public init(directPlayMode: DirectPlayMode = .preferred, advancedEngineMode: AdvancedEngineMode = .automatic,
                maxStreamingBitrate: Int? = nil, preferHDRPicture: Bool = true, allowBurnInSubtitles: Bool = true) {
        self.directPlayMode = directPlayMode
        self.advancedEngineMode = advancedEngineMode
        self.maxStreamingBitrate = maxStreamingBitrate
        self.preferHDRPicture = preferHDRPicture
        self.allowBurnInSubtitles = allowBurnInSubtitles
    }

    public static let `default` = PlaybackPreferences()
}
