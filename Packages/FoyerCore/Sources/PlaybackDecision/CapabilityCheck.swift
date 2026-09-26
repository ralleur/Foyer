import Foundation
import JellyfinKit

/// Result of asking "can engine X play this media source as-is?".
public struct CapabilityResult: Sendable, Hashable {
    public var containerOK: Bool
    public var videoOK: Bool
    public var audioOK: Bool
    public var subtitleOK: Bool
    /// Why direct play is not possible (empty when it is).
    public var blockers: [String]
    /// Positive facts worth logging ("HEVC hardware decode", "DTS-HD decoded locally").
    public var notes: [String]
    /// Quality compromises when this path is taken (e.g. HDR tone-mapped to SDR).
    public var compromises: [String]

    public var canDirectPlay: Bool { containerOK && videoOK && audioOK && subtitleOK }

    public static let unavailable = CapabilityResult(containerOK: false, videoOK: false, audioOK: false, subtitleOK: false,
                                                     blockers: ["engine not available"], notes: [], compromises: [])
}

/// Container families as far as playback engines care.
public enum ContainerFamily: String, Sendable {
    case mp4, mov, mkv, webm, mpegts, avi, other

    public init(tokens: [String]) {
        let set = Set(tokens)
        if !set.isDisjoint(with: ["mp4", "m4v", "isom", "mpeg4"]) { self = .mp4; return }
        if set.contains("mov") || set.contains("quicktime") { self = .mov; return }
        if !set.isDisjoint(with: ["mkv", "matroska", "mka"]) { self = .mkv; return }
        if set.contains("webm") { self = .webm; return }
        if !set.isDisjoint(with: ["ts", "mpegts", "m2ts", "mts", "mpeg", "mpg"]) { self = .mpegts; return }
        if set.contains("avi") { self = .avi; return }
        self = .other
    }

    public var isMP4Family: Bool { self == .mp4 || self == .mov }
}

/// Capability model of AVFoundation on tvOS 17+ (the "native" engine).
public enum NativeCapability {
    public static func check(source: MediaSource, video: MediaStream?, audio: MediaStream?, subtitle: MediaStream?,
                             capabilities caps: DeviceCapabilities) -> CapabilityResult {
        var blockers: [String] = []
        var notes: [String] = []
        var compromises: [String] = []

        // Container
        let family = ContainerFamily(tokens: source.containerTokens)
        let containerOK = family.isMP4Family
        if containerOK {
            notes.append("\(family == .mov ? "MOV" : "MP4") container plays natively")
        } else {
            blockers.append("\(source.container ?? "unknown") container is not supported by AVFoundation (only MP4/MOV)")
        }

        // Video
        var videoOK = true
        if let video {
            let (ok, reasons, positives) = videoCompatible(video, family: family, caps: caps, checkTag: true)
            videoOK = ok
            blockers.append(contentsOf: reasons)
            notes.append(contentsOf: positives)
        }

        // Audio
        var audioOK = true
        if let audio {
            let (ok, reason, positive) = audioCompatible(audio, caps: caps)
            audioOK = ok
            if let reason { blockers.append(reason) }
            if let positive { notes.append(positive) }
        }

        // Subtitles
        var subtitleOK = true
        if let subtitle {
            if subtitle.isTextSubtitle {
                notes.append("\(subtitle.technicalLabel) subtitles rendered by Foyer")
            } else {
                subtitleOK = false
                blockers.append("\(subtitle.technicalLabel) subtitles are bitmaps; AVFoundation cannot render them")
            }
        }

        if video?.isHDR == true, videoOK {
            notes.append("\(video?.effectiveVideoRange.displayName ?? "HDR") output by the system player")
        }
        if let ch = audio?.channels, ch > caps.maxOutputChannels {
            compromises.append("\(ch) channels downmixed to \(caps.maxOutputChannels) by the system")
        }

        return CapabilityResult(containerOK: containerOK, videoOK: videoOK, audioOK: audioOK, subtitleOK: subtitleOK,
                                blockers: blockers, notes: notes, compromises: compromises)
    }

    /// Whether the video *elementary stream* is fine for AVFoundation once the server has remuxed it
    /// into fMP4/HLS (container and codec tag problems disappear, everything else stays).
    public static func videoCompatibleAfterRemux(_ video: MediaStream?, caps: DeviceCapabilities) -> Bool {
        guard let video else { return true }
        return videoCompatible(video, family: .mp4, caps: caps, checkTag: false).ok
    }

    static func videoCompatible(_ video: MediaStream, family: ContainerFamily, caps: DeviceCapabilities, checkTag: Bool)
        -> (ok: Bool, blockers: [String], notes: [String]) {
        var blockers: [String] = []
        var notes: [String] = []
        let codec = video.normalizedCodec
        let profile = video.normalizedProfile
        let height = video.height ?? 0
        let width = video.width ?? 0
        let range = video.effectiveVideoRange

        if width > caps.maxVideoWidth || height > caps.maxVideoHeight {
            blockers.append("\(width)×\(height) exceeds device maximum \(caps.maxVideoWidth)×\(caps.maxVideoHeight)")
        }
        if let fps = video.frameRate, fps > caps.maxFrameRate + 0.5 {
            blockers.append("\(fps) fps exceeds \(Int(caps.maxFrameRate)) fps")
        }
        if video.isInterlaced == true {
            blockers.append("interlaced video is deinterlaced only by the advanced engine")
        }

        switch codec {
        case "h264", "avc":
            if profile.contains("high 10") || profile.contains("high 4:2:2") || profile.contains("high 4:4:4") || (video.bitDepth ?? 8) > 8 {
                blockers.append("H.264 \(video.profile ?? "10-bit") has no hardware decoder")
            } else if let level = video.level, level > 52 {
                blockers.append("H.264 level \(level) above 5.2")
            } else {
                notes.append("H.264 hardware decode")
            }
        case "hevc", "h265":
            if !caps.supportsHEVCHardware {
                blockers.append("no HEVC hardware decoder")
            }
            if profile.contains("rext") || profile.contains("4:2:2") || profile.contains("4:4:4") || (video.bitDepth ?? 8) > 10 {
                blockers.append("HEVC \(video.profile ?? "") profile not supported by hardware")
            } else if (video.bitDepth ?? 8) == 10, !caps.supportsHEVC10Bit {
                blockers.append("HEVC 10-bit not supported on this device")
            } else {
                notes.append("HEVC hardware decode")
            }
            if checkTag, family.isMP4Family {
                let tag = (video.codecTag ?? "").lowercased()
                if tag == "hev1" {
                    blockers.append("HEVC tagged 'hev1' in MP4 needs retagging to 'hvc1' (server remux)")
                } else if video.isDolbyVision, !(tag == "dvh1" || tag == "dvhe" || tag == "hvc1") {
                    blockers.append("Dolby Vision requires 'dvh1' tagging (server remux)")
                }
            }
        case "av1":
            if caps.supportsAV1Hardware {
                notes.append("AV1 hardware decode")
            } else {
                blockers.append("no AV1 hardware decoder")
            }
        case "mpeg4":
            if family.isMP4Family { notes.append("MPEG-4 Part 2 decode") } else { blockers.append("MPEG-4 Part 2 only in MP4") }
        case "":
            break
        default:
            blockers.append("\(VideoCodecName(codec: codec).display) is not decodable by AVFoundation")
        }

        // Dynamic range
        if range.isHDR {
            if range.isDolbyVision {
                let dvProfile = video.dvProfile ?? 0
                if dvProfile == 5 {
                    if !caps.supportsDolbyVision {
                        blockers.append("Dolby Vision profile 5 needs a Dolby Vision capable device/display")
                    } else {
                        notes.append("Dolby Vision profile 5")
                    }
                } else if range.hasHDRCompatibleBaseLayer || dvProfile == 7 || dvProfile == 8 {
                    if caps.supportsDolbyVision {
                        notes.append("Dolby Vision profile \(dvProfile) (HDR10 compatible)")
                    } else if caps.supportsHDR10 {
                        notes.append("Dolby Vision profile \(dvProfile) played as HDR10 base layer")
                    } else {
                        blockers.append("HDR content on a device without HDR output")
                    }
                } else if !caps.supportsDolbyVision {
                    blockers.append("Dolby Vision profile \(dvProfile) not supported")
                }
            } else if range == .hlg || range == .doviWithHLG {
                if !caps.supportsHLG { blockers.append("HLG not supported by this device/display") }
            } else if !caps.supportsHDR10 {
                blockers.append("HDR10 not supported by this device/display")
            }
        }

        return (blockers.isEmpty, blockers, notes)
    }

    static func audioCompatible(_ audio: MediaStream, caps: DeviceCapabilities) -> (ok: Bool, blocker: String?, note: String?) {
        let codec = audio.normalizedCodec
        let label = audio.technicalLabel
        switch codec {
        case "aac", "mp3", "alac", "flac":
            return (true, nil, "\(label) decoded by the system")
        case "ac3", "eac3":
            if caps.supportsDolbyPassthrough {
                return (true, nil, "\(label) passed through to the receiver")
            }
            return (true, nil, "\(label) decoded by the system")
        case "pcm_s16le", "pcm_s24le", "pcm_s16be", "pcm_s24be", "pcm_f32le", "pcm_s32le":
            return (true, nil, "PCM audio")
        case "dts":
            return (false, "\(label) cannot be decoded or passed through by AVFoundation", nil)
        case "truehd":
            return (false, "\(label) cannot be decoded by AVFoundation", nil)
        case "opus", "vorbis", "mp2", "wmav2", "wmapro", "wmav1":
            return (false, "\(label) is not supported by AVFoundation", nil)
        case "":
            return (true, nil, nil)
        default:
            return (false, "\(label) is not supported by AVFoundation", nil)
        }
    }
}

/// Capability model of the mpv/FFmpeg based advanced engine.
public enum AdvancedCapability {
    public static func check(source: MediaSource, video: MediaStream?, audio: MediaStream?, subtitle: MediaStream?,
                             capabilities caps: DeviceCapabilities) -> CapabilityResult {
        guard caps.advancedEngineAvailable else { return .unavailable }
        var blockers: [String] = []
        var notes: [String] = []
        var compromises: [String] = []

        let family = ContainerFamily(tokens: source.containerTokens)
        let videoType = (source.videoType ?? "").lowercased()
        var containerOK = true
        if videoType == "bluray" || videoType == "dvd" || videoType == "iso" {
            containerOK = false
            blockers.append("disc folder structures are not streamed directly")
        } else {
            notes.append("\(family == .other ? (source.container ?? "container") : family.rawValue.uppercased()) demuxed by FFmpeg")
        }

        var videoOK = true
        if let video {
            let codec = video.normalizedCodec
            let height = video.height ?? 0
            let width = video.width ?? 0
            if width > caps.maxVideoWidth || height > caps.maxVideoHeight {
                videoOK = false
                blockers.append("\(width)×\(height) exceeds device maximum")
            }
            if let fps = video.frameRate, fps > caps.maxFrameRate + 0.5 {
                videoOK = false
                blockers.append("\(fps) fps exceeds \(Int(caps.maxFrameRate)) fps")
            }
            switch codec {
            case "h264", "avc":
                if (video.bitDepth ?? 8) > 8 || video.normalizedProfile.contains("high 10") {
                    if height > caps.advancedEngineMaxSoftwareDecodeHeight {
                        videoOK = false
                        blockers.append("H.264 10-bit at \(height)p exceeds software decode budget")
                    } else {
                        notes.append("H.264 10-bit software decode")
                    }
                } else {
                    notes.append("H.264 VideoToolbox decode")
                }
            case "hevc", "h265":
                if caps.supportsHEVCHardware, (video.bitDepth ?? 8) <= 10, !video.normalizedProfile.contains("rext") {
                    notes.append("HEVC VideoToolbox decode")
                } else if height <= caps.advancedEngineMaxSoftwareDecodeHeight {
                    notes.append("HEVC software decode")
                } else {
                    videoOK = false
                    blockers.append("HEVC \(video.profile ?? "") at \(height)p has no hardware decoder")
                }
            case "av1":
                if caps.supportsAV1Hardware {
                    notes.append("AV1 VideoToolbox decode")
                } else if height <= caps.advancedEngineMaxSoftwareDecodeHeight {
                    notes.append("AV1 software decode (dav1d)")
                } else {
                    videoOK = false
                    blockers.append("AV1 \(height)p exceeds software decode budget")
                }
            case "vp9", "vp8":
                if height <= caps.advancedEngineMaxSoftwareDecodeHeight {
                    notes.append("\(codec.uppercased()) software decode")
                } else {
                    videoOK = false
                    blockers.append("\(codec.uppercased()) \(height)p exceeds software decode budget")
                }
            case "mpeg4", "mpeg2video", "mpeg1video", "vc1", "wmv3", "msmpeg4v3", "msmpeg4v2", "theora", "mjpeg", "h263", "flv1":
                notes.append("\(VideoCodecName(codec: codec).display) software decode")
            case "":
                break
            default:
                videoOK = false
                blockers.append("\(codec) is not a supported video codec")
            }
            if video.isInterlaced == true { notes.append("deinterlaced by the advanced engine") }
            if video.isHDR {
                if caps.advancedEngineSupportsHDROutput {
                    notes.append("\(video.effectiveVideoRange.displayName) output")
                } else {
                    compromises.append("\(video.effectiveVideoRange.displayName) tone-mapped to SDR by the advanced engine")
                }
            }
        }

        var audioOK = true
        if let audio {
            let codec = audio.normalizedCodec
            switch codec {
            case "aac", "ac3", "eac3", "dts", "truehd", "flac", "mp3", "mp2", "opus", "vorbis", "alac", "wmav2", "wmapro", "wmav1", "":
                notes.append("\(audio.technicalLabel) decoded locally to PCM")
            case let c where c.hasPrefix("pcm"):
                notes.append("PCM audio")
            default:
                audioOK = false
                blockers.append("\(codec) is not a supported audio codec")
            }
            if let ch = audio.channels, ch > caps.maxOutputChannels {
                compromises.append("\(ch) channels downmixed to \(caps.maxOutputChannels)")
            }
        }

        var subtitleOK = true
        if let subtitle {
            let format = SubtitleFormat(codec: subtitle.normalizedCodec)
            if format.isText || format.isBitmap {
                notes.append("\(format.display) subtitles rendered locally")
            } else {
                subtitleOK = false
                blockers.append("\(subtitle.normalizedCodec) subtitles are not supported")
            }
        }

        return CapabilityResult(containerOK: containerOK, videoOK: videoOK, audioOK: audioOK, subtitleOK: subtitleOK,
                                blockers: blockers, notes: notes, compromises: compromises)
    }
}
