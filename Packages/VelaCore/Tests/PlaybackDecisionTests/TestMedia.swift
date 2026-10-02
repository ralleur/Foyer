import Foundation
@testable import JellyfinKit
@testable import PlaybackDecision

/// Builders for the media test matrix.
enum TestMedia {
    static func video(codec: String, width: Int = 1920, height: Int = 1080, range: VideoRangeType = .sdr, profile: String? = nil,
                      bitDepth: Int? = nil, tag: String? = nil, fps: Double = 23.976, interlaced: Bool = false,
                      dvProfile: Int? = nil, level: Double? = nil) -> MediaStream {
        var s = MediaStream(index: 0, type: .video, codec: codec)
        s.width = width
        s.height = height
        s.videoRangeType = range
        s.profile = profile ?? (codec == "hevc" ? (bitDepth == 10 || range.isHDR ? "Main 10" : "Main") : "High")
        s.bitDepth = bitDepth ?? (range.isHDR ? 10 : 8)
        s.codecTag = tag ?? (codec == "hevc" ? "hvc1" : (codec == "h264" ? "avc1" : nil))
        s.averageFrameRate = fps
        s.isInterlaced = interlaced
        s.dvProfile = dvProfile
        s.level = level
        return s
    }

    static func audio(index: Int, codec: String, language: String = "eng", channels: Int = 6, isDefault: Bool = false,
                      title: String? = nil, profile: String? = nil, isOriginal: Bool? = nil) -> MediaStream {
        var s = MediaStream(index: index, type: .audio, codec: codec, language: language)
        s.channels = channels
        s.isDefault = isDefault
        s.title = title
        s.profile = profile
        s.isOriginal = isOriginal
        return s
    }

    static func subtitle(index: Int, codec: String, language: String = "eng", forced: Bool = false, isDefault: Bool = false,
                         external: Bool = false, sdh: Bool = false, title: String? = nil) -> MediaStream {
        var s = MediaStream(index: index, type: .subtitle, codec: codec, language: language)
        s.isForced = forced
        s.isDefault = isDefault
        s.isExternal = external
        s.isHearingImpaired = sdh
        s.isTextSubtitleStream = SubtitleFormat(codec: codec).isText
        s.title = title
        return s
    }

    static func source(container: String, streams: [MediaStream]) -> MediaSource {
        var s = MediaSource(id: "ms1", container: container, mediaStreams: streams)
        s.supportsDirectPlay = true
        s.supportsDirectStream = true
        s.supportsTranscoding = true
        return s
    }

    // Common fixtures
    static let mp4H264AACSRT = source(container: "mp4", streams: [
        video(codec: "h264"), audio(index: 1, codec: "aac", channels: 2, isDefault: true), subtitle(index: 2, codec: "subrip", language: "ger", external: true),
    ])
    static let mp4H264AC3 = source(container: "mov,mp4,m4a,3gp,3g2,mj2", streams: [
        video(codec: "h264"), audio(index: 1, codec: "ac3", channels: 6, isDefault: true),
    ])
    static let mkv4KHEVCSDR = source(container: "mkv", streams: [
        video(codec: "hevc", width: 3840, height: 2160), audio(index: 1, codec: "eac3", isDefault: true),
    ])
    static let mkv4KHEVCHDR10 = source(container: "mkv", streams: [
        video(codec: "hevc", width: 3840, height: 2160, range: .hdr10), audio(index: 1, codec: "eac3", isDefault: true),
    ])
    static let mp44KHEVCDV8 = source(container: "mp4", streams: [
        video(codec: "hevc", width: 3840, height: 2160, range: .doviWithHDR10, tag: "dvh1", dvProfile: 8), audio(index: 1, codec: "eac3", isDefault: true),
    ])
    static let mkv4KHEVCDV5 = source(container: "mkv", streams: [
        video(codec: "hevc", width: 3840, height: 2160, range: .dovi, tag: "dvhe", dvProfile: 5), audio(index: 1, codec: "eac3", isDefault: true),
    ])
    static let mkvHEVCDTS = source(container: "mkv", streams: [
        video(codec: "hevc"), audio(index: 1, codec: "dts", isDefault: true),
    ])
    static let mkvHEVCDTSHD = source(container: "mkv", streams: [
        video(codec: "hevc"), audio(index: 1, codec: "dts", isDefault: true, profile: "DTS-HD MA"),
    ])
    static let mkvHEVCTrueHD = source(container: "mkv", streams: [
        video(codec: "hevc"), audio(index: 1, codec: "truehd", channels: 8, isDefault: true, profile: "Dolby TrueHD + Dolby Atmos"),
    ])
    static let mkv4KHDRTrueHD = source(container: "mkv", streams: [
        video(codec: "hevc", width: 3840, height: 2160, range: .hdr10), audio(index: 1, codec: "truehd", channels: 8, isDefault: true),
    ])
    static let mkvASS = source(container: "mkv", streams: [
        video(codec: "h264"), audio(index: 1, codec: "aac", language: "jpn", channels: 2, isDefault: true),
        subtitle(index: 2, codec: "ass", language: "ger"),
    ])
    static let mkvHDRPGS = source(container: "mkv", streams: [
        video(codec: "hevc", width: 3840, height: 2160, range: .hdr10), audio(index: 1, codec: "eac3", isDefault: true),
        subtitle(index: 2, codec: "PGSSUB", language: "ger"),
    ])
    static let mp4Hev1 = source(container: "mp4", streams: [
        video(codec: "hevc", tag: "hev1"), audio(index: 1, codec: "aac", channels: 2, isDefault: true),
    ])
}
