import Foundation
import VelaFoundation

public struct MediaStream: Codable, Hashable, Sendable {
    public var index: Int
    public var type: MediaStreamKind?
    public var codec: String?
    public var codecTag: String?
    public var language: String?
    public var title: String?
    public var displayTitle: String?
    public var profile: String?
    public var level: Double?
    public var isDefault: Bool?
    public var isForced: Bool?
    public var isExternal: Bool?
    public var isHearingImpaired: Bool?
    public var isOriginal: Bool?
    public var isTextSubtitleStream: Bool?
    public var supportsExternalStream: Bool?
    public var isInterlaced: Bool?
    public var isAnamorphic: Bool?
    public var isAVC: Bool?
    public var deliveryMethod: SubtitleDeliveryMethod?
    public var deliveryUrl: String?
    public var path: String?
    // Video
    public var width: Int?
    public var height: Int?
    public var bitRate: Int?
    public var bitDepth: Int?
    public var realFrameRate: Double?
    public var averageFrameRate: Double?
    public var referenceFrameRate: Double?
    public var aspectRatio: String?
    public var pixelFormat: String?
    public var colorSpace: String?
    public var colorTransfer: String?
    public var colorPrimaries: String?
    public var colorRange: String?
    public var videoRangeType: VideoRangeType?
    public var videoRange: String?
    public var videoDoViTitle: String?
    public var dvProfile: Int?
    public var dvLevel: Int?
    public var dvBlSignalCompatibilityId: Int?
    public var rpuPresentFlag: Int?
    public var elPresentFlag: Int?
    public var blPresentFlag: Int?
    public var isHdr10PlusPresent: Bool?
    public var refFrames: Int?
    public var nalLengthSize: String?
    // Audio
    public var channels: Int?
    public var channelLayout: String?
    public var sampleRate: Int?
    public var audioSpatialFormat: String?

    public init(index: Int, type: MediaStreamKind, codec: String? = nil, language: String? = nil) {
        self.index = index
        self.type = type
        self.codec = codec
        self.language = language
    }

    enum CodingKeys: String, CodingKey {
        case index = "Index"
        case type = "Type"
        case codec = "Codec"
        case codecTag = "CodecTag"
        case language = "Language"
        case title = "Title"
        case displayTitle = "DisplayTitle"
        case profile = "Profile"
        case level = "Level"
        case isDefault = "IsDefault"
        case isForced = "IsForced"
        case isExternal = "IsExternal"
        case isHearingImpaired = "IsHearingImpaired"
        case isOriginal = "IsOriginal"
        case isTextSubtitleStream = "IsTextSubtitleStream"
        case supportsExternalStream = "SupportsExternalStream"
        case isInterlaced = "IsInterlaced"
        case isAnamorphic = "IsAnamorphic"
        case isAVC = "IsAVC"
        case deliveryMethod = "DeliveryMethod"
        case deliveryUrl = "DeliveryUrl"
        case path = "Path"
        case width = "Width"
        case height = "Height"
        case bitRate = "BitRate"
        case bitDepth = "BitDepth"
        case realFrameRate = "RealFrameRate"
        case averageFrameRate = "AverageFrameRate"
        case referenceFrameRate = "ReferenceFrameRate"
        case aspectRatio = "AspectRatio"
        case pixelFormat = "PixelFormat"
        case colorSpace = "ColorSpace"
        case colorTransfer = "ColorTransfer"
        case colorPrimaries = "ColorPrimaries"
        case colorRange = "ColorRange"
        case videoRangeType = "VideoRangeType"
        case videoRange = "VideoRange"
        case videoDoViTitle = "VideoDoViTitle"
        case dvProfile = "DvProfile"
        case dvLevel = "DvLevel"
        case dvBlSignalCompatibilityId = "DvBlSignalCompatibilityId"
        case rpuPresentFlag = "RpuPresentFlag"
        case elPresentFlag = "ElPresentFlag"
        case blPresentFlag = "BlPresentFlag"
        case isHdr10PlusPresent = "Hdr10PlusPresentFlag"
        case refFrames = "RefFrames"
        case nalLengthSize = "NalLengthSize"
        case channels = "Channels"
        case channelLayout = "ChannelLayout"
        case sampleRate = "SampleRate"
        case audioSpatialFormat = "AudioSpatialFormat"
    }

    // MARK: Derived

    public var normalizedCodec: String { (codec ?? "").lowercased() }
    public var normalizedProfile: String { (profile ?? "").lowercased() }
    public var normalizedLanguage: String? { LanguageCode.normalize(language) }

    public var frameRate: Double? { averageFrameRate ?? realFrameRate ?? referenceFrameRate }

    public var isVideo: Bool { type == .video }
    public var isAudio: Bool { type == .audio }
    public var isSubtitle: Bool { type == .subtitle }

    /// True for subtitle formats that are plain text (SRT, ASS, WebVTT, ...).
    public var isTextSubtitle: Bool {
        if let flag = isTextSubtitleStream { return flag }
        return SubtitleFormat(codec: normalizedCodec).isText
    }

    public var isBitmapSubtitle: Bool { isSubtitle && !isTextSubtitle }

    public var isCommentary: Bool {
        let t = (title ?? "").lowercased()
        return t.contains("commentary") || t.contains("kommentar")
    }

    public var isSDH: Bool {
        if isHearingImpaired == true { return true }
        let t = (title ?? "").lowercased()
        return t.contains("sdh") || t.contains("cc") && t.count <= 4 || t.contains("hearing") || t.contains("hörgeschädigt")
    }

    /// Resolves the effective dynamic range, falling back to colour metadata for older servers.
    public var effectiveVideoRange: VideoRangeType {
        if let vr = videoRangeType, vr != .unknown { return vr }
        if let dv = dvProfile, dv > 0 { return .dovi }
        let transfer = (colorTransfer ?? "").lowercased()
        if transfer.contains("smpte2084") { return .hdr10 }
        if transfer.contains("arib-std-b67") { return .hlg }
        if (videoRange ?? "").uppercased() == "HDR" { return .hdr10 }
        return .sdr
    }

    public var isHDR: Bool { effectiveVideoRange.isHDR }
    public var isDolbyVision: Bool { effectiveVideoRange.isDolbyVision || (dvProfile ?? 0) > 0 }

    /// Dolby Atmos / DTS:X detection based on server-provided metadata.
    public var isObjectAudio: Bool {
        let spatial = (audioSpatialFormat ?? "").lowercased()
        if spatial.contains("atmos") || spatial.contains("dts:x") || spatial.contains("dtsx") { return true }
        let p = normalizedProfile
        return p.contains("atmos") || p.contains("dts:x")
    }

    /// "4K", "1080p", "720p" or "576p" based on width first (scope aspect ratios shrink the height).
    public var resolutionLabel: String? {
        let w = width ?? 0
        let h = height ?? 0
        guard w > 0 || h > 0 else { return nil }
        if w >= 3000 || h >= 2000 { return "4K" }
        if w >= 1800 || h >= 1000 { return "1080p" }
        if w >= 1200 || h >= 700 { return "720p" }
        return h > 0 ? "\(h)p" : nil
    }

    /// A short technical label like "HEVC 4K HDR10" or "TrueHD 7.1".
    public var technicalLabel: String {
        switch type {
        case .video?:
            var parts: [String] = [VideoCodecName(codec: normalizedCodec).display]
            if let label = resolutionLabel { parts.append(label) }
            let range = effectiveVideoRange
            if range != .sdr && range != .unknown { parts.append(range.displayName) }
            return parts.joined(separator: " ")
        case .audio?:
            var parts: [String] = [AudioCodecName(codec: normalizedCodec, profile: normalizedProfile).display]
            if isObjectAudio, !parts[0].lowercased().contains("atmos") { parts.append("Atmos") }
            if let ch = channels { parts.append(ChannelLayoutName(channels: ch).display) }
            return parts.joined(separator: " ")
        case .subtitle?:
            return SubtitleFormat(codec: normalizedCodec).display
        default:
            return normalizedCodec.uppercased()
        }
    }
}

public extension VideoRangeType {
    var displayName: String {
        switch self {
        case .sdr: "SDR"
        case .hdr10: "HDR10"
        case .hdr10Plus: "HDR10+"
        case .hlg: "HLG"
        case .dovi, .doviWithEL: "Dolby Vision"
        case .doviWithHDR10, .doviWithHDR10Plus, .doviWithELHDR10Plus: "Dolby Vision · HDR10"
        case .doviWithHLG: "Dolby Vision · HLG"
        case .doviWithSDR: "Dolby Vision · SDR"
        default: rawValue
        }
    }
}

public struct VideoCodecName: Sendable {
    public let codec: String
    public init(codec: String) { self.codec = codec.lowercased() }
    public var display: String {
        switch codec {
        case "h264", "avc": "H.264"
        case "hevc", "h265": "HEVC"
        case "av1": "AV1"
        case "vp9": "VP9"
        case "vp8": "VP8"
        case "mpeg4": "MPEG-4"
        case "mpeg2video": "MPEG-2"
        case "vc1": "VC-1"
        default: codec.uppercased()
        }
    }
}

public struct AudioCodecName: Sendable {
    public let codec: String
    public let profile: String
    public init(codec: String, profile: String = "") {
        self.codec = codec.lowercased()
        self.profile = profile.lowercased()
    }
    public var display: String {
        switch codec {
        case "aac": return "AAC"
        case "ac3": return "Dolby Digital"
        case "eac3": return profile.contains("atmos") ? "Dolby Digital Plus Atmos" : "Dolby Digital Plus"
        case "truehd": return profile.contains("atmos") ? "Dolby TrueHD Atmos" : "Dolby TrueHD"
        case "dts":
            if profile.contains("dts-hd ma") || (profile.contains("ma") && profile.contains("hd")) { return "DTS-HD MA" }
            if profile.contains("dts-hd hra") || profile.contains("hra") { return "DTS-HD HRA" }
            if profile.contains("dts:x") || profile.contains("dtsx") { return "DTS:X" }
            if profile.contains("express") { return "DTS Express" }
            return "DTS"
        case "flac": return "FLAC"
        case "alac": return "ALAC"
        case "mp3": return "MP3"
        case "mp2": return "MP2"
        case "opus": return "Opus"
        case "vorbis": return "Vorbis"
        default:
            if codec.hasPrefix("pcm") { return "PCM" }
            return codec.uppercased()
        }
    }
}

public struct ChannelLayoutName: Sendable {
    public let channels: Int
    public init(channels: Int) { self.channels = channels }
    public var display: String {
        switch channels {
        case 1: "Mono"
        case 2: "Stereo"
        case 3: "2.1"
        case 6: "5.1"
        case 7: "6.1"
        case 8: "7.1"
        default: "\(channels) ch"
        }
    }
}

/// Subtitle codec families as reported by Jellyfin/FFmpeg.
public struct SubtitleFormat: Hashable, Sendable {
    public let codec: String
    public init(codec: String) { self.codec = codec.lowercased() }

    public static let subrip = SubtitleFormat(codec: "subrip")
    public static let ass = SubtitleFormat(codec: "ass")
    public static let ssa = SubtitleFormat(codec: "ssa")
    public static let webvtt = SubtitleFormat(codec: "webvtt")
    public static let movText = SubtitleFormat(codec: "mov_text")
    public static let pgs = SubtitleFormat(codec: "pgssub")
    public static let dvdsub = SubtitleFormat(codec: "dvdsub")
    public static let dvbsub = SubtitleFormat(codec: "dvbsub")

    public var isText: Bool {
        switch codec {
        case "subrip", "srt", "ass", "ssa", "webvtt", "vtt", "mov_text", "text", "ttml", "microdvd", "subviewer", "sami", "smi", "mpl2", "vplayer", "jacosub", "realtext", "pjs", "stl": true
        default: false
        }
    }

    public var isASS: Bool { codec == "ass" || codec == "ssa" }

    public var isBitmap: Bool {
        switch codec {
        case "pgssub", "hdmv_pgs_subtitle", "pgs", "dvdsub", "dvd_subtitle", "dvbsub", "dvb_subtitle", "xsub", "vobsub", "sup": true
        default: false
        }
    }

    public var display: String {
        switch codec {
        case "subrip", "srt": "SRT"
        case "ass": "ASS"
        case "ssa": "SSA"
        case "webvtt", "vtt": "WebVTT"
        case "mov_text": "MP4 Text"
        case "pgssub", "hdmv_pgs_subtitle", "pgs", "sup": "PGS"
        case "dvdsub", "dvd_subtitle", "vobsub": "VobSub"
        case "dvbsub", "dvb_subtitle": "DVB"
        case "ttml": "TTML"
        default: codec.uppercased()
        }
    }

    /// File extension Jellyfin uses when serving the stream externally.
    public var externalFileExtension: String {
        switch codec {
        case "ass": "ass"
        case "ssa": "ssa"
        case "webvtt", "vtt": "vtt"
        default: "srt"
        }
    }
}
