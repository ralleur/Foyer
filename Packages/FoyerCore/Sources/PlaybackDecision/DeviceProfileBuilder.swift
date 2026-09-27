import Foundation
import JellyfinKit

/// Produces the Jellyfin `DeviceProfile` that matches what a given engine can do,
/// so the server's PlaybackInfo answer agrees with our local decision.
public struct DeviceProfileBuilder: Sendable {
    public var capabilities: DeviceCapabilities
    public var preferences: PlaybackPreferences

    public init(capabilities: DeviceCapabilities, preferences: PlaybackPreferences) {
        self.capabilities = capabilities
        self.preferences = preferences
    }

    public func profile(for engine: PlaybackEngineKind, allowBurnIn: Bool) -> DeviceProfile {
        switch engine {
        case .native: nativeProfile(allowBurnIn: allowBurnIn)
        case .advanced: advancedProfile(allowBurnIn: allowBurnIn)
        }
    }

    // MARK: Shared pieces

    /// Jellyfin defaults both profile bitrates to 8 Mbit/s when a client omits them — which silently forces
    /// 4K remuxes into a re-encode. "Original quality" therefore sends an explicit, generous ceiling.
    public static let unlimitedBitrate = 200_000_000
    private var maxBitrate: Int { preferences.maxStreamingBitrate ?? Self.unlimitedBitrate }

    private var nativeVideoCodecs: [String] {
        var codecs = ["h264"]
        if capabilities.supportsHEVCHardware { codecs.insert("hevc", at: 0) }
        if capabilities.supportsAV1Hardware { codecs.insert("av1", at: 0) }
        codecs.append("mpeg4")
        return codecs
    }

    private var nativeAudioCodecs: [String] {
        ["aac", "ac3", "eac3", "alac", "flac", "mp3", "pcm_s16le", "pcm_s24le", "pcm_s16be", "pcm_s24be"]
    }

    private var supportedVideoRangeTypes: [VideoRangeType] {
        var types: [VideoRangeType] = [.sdr, .doviWithSDR]
        if capabilities.supportsHLG {
            types.append(.hlg)
            types.append(.doviWithHLG)
        }
        if capabilities.supportsHDR10 {
            types.append(contentsOf: [.hdr10, .hdr10Plus, .doviWithHDR10, .doviWithHDR10Plus, .doviWithEL, .doviWithELHDR10Plus])
        }
        if capabilities.supportsDolbyVision {
            types.append(.dovi)
        }
        return types
    }

    /// HLS/fMP4 transcoding profile shared by both engines (the native engine plays the result).
    private var hlsTranscodingProfile: TranscodingProfile {
        var videoCodecs = ["h264"]
        if capabilities.supportsHEVCHardware { videoCodecs.insert("hevc", at: 0) }
        return TranscodingProfile(
            container: "mp4",
            type: .video,
            videoCodec: videoCodecs.joined(separator: ","),
            // Order matters: the first entry is the target when the source cannot be copied.
            audioCodec: ["eac3", "ac3", "aac", "alac", "flac", "mp3"].joined(separator: ","),
            protocol: "hls",
            context: .streaming,
            maxAudioChannels: String(min(capabilities.maxOutputChannels, 8)),
            minSegments: 2,
            breakOnNonKeyFrames: true,
            enableSubtitlesInManifest: false
        )
    }

    private func videoCodecProfiles(includeTagCondition: Bool) -> [CodecProfile] {
        var profiles: [CodecProfile] = []
        let rangeValues = supportedVideoRangeTypes.map(\.rawValue).joined(separator: "|")

        profiles.append(CodecProfile(type: .video, codec: "h264", conditions: [
            ProfileCondition(.videoProfile, .equalsAny, "high|main|baseline|constrained baseline|constrained high", isRequired: false),
            ProfileCondition(.videoLevel, .lessThanEqual, "52", isRequired: false),
            ProfileCondition(.videoBitDepth, .lessThanEqual, "8", isRequired: false),
            ProfileCondition(.isInterlaced, .notEquals, "true", isRequired: false),
            ProfileCondition(.videoFramerate, .lessThanEqual, String(Int(capabilities.maxFrameRate)), isRequired: false),
            ProfileCondition(.width, .lessThanEqual, String(capabilities.maxVideoWidth), isRequired: false),
        ]))

        if capabilities.supportsHEVCHardware {
            var conditions = [
                ProfileCondition(.videoProfile, .equalsAny, capabilities.supportsHEVC10Bit ? "main|main 10" : "main", isRequired: false),
                ProfileCondition(.videoLevel, .lessThanEqual, "183", isRequired: false),
                ProfileCondition(.videoBitDepth, .lessThanEqual, capabilities.supportsHEVC10Bit ? "10" : "8", isRequired: false),
                ProfileCondition(.videoRangeType, .equalsAny, rangeValues, isRequired: false),
                ProfileCondition(.isInterlaced, .notEquals, "true", isRequired: false),
                ProfileCondition(.videoFramerate, .lessThanEqual, String(Int(capabilities.maxFrameRate)), isRequired: false),
                ProfileCondition(.width, .lessThanEqual, String(capabilities.maxVideoWidth), isRequired: false),
            ]
            if includeTagCondition {
                // Not required: MKV sources carry no codec tag at all, and a required condition makes Jellyfin
                // re-encode the video ("VideoCodecTagNotSupported") instead of remuxing it with `-tag:v hvc1`.
                // An MP4 that is tagged `hev1` still fails the check and is remuxed rather than direct-played.
                conditions.append(ProfileCondition(.videoCodecTag, .equalsAny, "hvc1|dvh1", isRequired: false))
            }
            profiles.append(CodecProfile(type: .video, codec: "hevc", conditions: conditions))
        }

        if capabilities.supportsAV1Hardware {
            profiles.append(CodecProfile(type: .video, codec: "av1", conditions: [
                ProfileCondition(.videoRangeType, .equalsAny, rangeValues, isRequired: false),
                ProfileCondition(.width, .lessThanEqual, String(capabilities.maxVideoWidth), isRequired: false),
            ]))
        }

        profiles.append(CodecProfile(type: .videoAudio, codec: nil, conditions: [
            ProfileCondition(.audioChannels, .lessThanEqual, String(min(capabilities.maxOutputChannels, 8)), isRequired: false),
        ]))
        return profiles
    }

    private func textSubtitleProfiles(method: SubtitleDeliveryMethod) -> [SubtitleProfile] {
        ["srt", "subrip", "ass", "ssa", "vtt", "webvtt", "ttml", "sub", "microdvd", "smi", "sami"].map { SubtitleProfile(format: $0, method: method) }
    }

    private func burnInSubtitleProfiles() -> [SubtitleProfile] {
        ["pgssub", "pgs", "dvdsub", "dvbsub", "vobsub", "xsub"].map { SubtitleProfile(format: $0, method: .encode) }
    }

    // MARK: Native (AVFoundation)

    func nativeProfile(allowBurnIn: Bool) -> DeviceProfile {
        var profile = DeviceProfile(name: "Foyer tvOS (native)", maxStreamingBitrate: maxBitrate, maxStaticBitrate: maxBitrate)
        let video = nativeVideoCodecs.joined(separator: ",")
        profile.directPlayProfiles = [
            DirectPlayProfile(container: "mp4,m4v", audioCodec: nativeAudioCodecs.joined(separator: ","), videoCodec: video),
            DirectPlayProfile(container: "mov", audioCodec: nativeAudioCodecs.joined(separator: ","), videoCodec: video),
        ]
        profile.transcodingProfiles = [hlsTranscodingProfile]
        profile.codecProfiles = videoCodecProfiles(includeTagCondition: true)
        var subs = textSubtitleProfiles(method: .external)
        subs.append(SubtitleProfile(format: "mov_text", method: .embed))
        subs.append(contentsOf: textSubtitleProfiles(method: .hls))
        if allowBurnIn { subs.append(contentsOf: burnInSubtitleProfiles()) }
        profile.subtitleProfiles = subs
        return profile
    }

    // MARK: Advanced (mpv / FFmpeg)

    func advancedProfile(allowBurnIn: Bool) -> DeviceProfile {
        var profile = DeviceProfile(name: "Foyer tvOS (advanced)", maxStreamingBitrate: maxBitrate, maxStaticBitrate: maxBitrate)
        let containers = "mkv,matroska,webm,mp4,m4v,mov,ts,mpegts,m2ts,mts,avi,flv,wmv,asf,3gp,3g2,ogv,ogm,mpeg,mpg,vob"
        let videoCodecs = "h264,hevc,av1,vp9,vp8,mpeg4,mpeg2video,mpeg1video,vc1,wmv3,msmpeg4v3,msmpeg4v2,theora,mjpeg,h263,flv1"
        let audioCodecs = "aac,ac3,eac3,dts,truehd,flac,mp3,mp2,opus,vorbis,alac,wmav2,wmapro,wmav1,pcm_s16le,pcm_s24le,pcm_s16be,pcm_s24be,pcm_f32le,pcm_s32le"
        profile.directPlayProfiles = [
            DirectPlayProfile(container: containers, audioCodec: audioCodecs, videoCodec: videoCodecs),
        ]
        profile.transcodingProfiles = [hlsTranscodingProfile]
        // Software decode budget for codecs without hardware support.
        let swHeight = String(capabilities.advancedEngineMaxSoftwareDecodeHeight)
        var codecProfiles: [CodecProfile] = [
            CodecProfile(type: .video, codec: "vp9,vp8,theora", conditions: [
                ProfileCondition(.height, .lessThanEqual, swHeight, isRequired: false),
            ]),
            CodecProfile(type: .video, codec: nil, conditions: [
                ProfileCondition(.width, .lessThanEqual, String(capabilities.maxVideoWidth), isRequired: false),
                ProfileCondition(.videoFramerate, .lessThanEqual, String(Int(capabilities.maxFrameRate)), isRequired: false),
            ]),
        ]
        if !capabilities.supportsAV1Hardware {
            codecProfiles.append(CodecProfile(type: .video, codec: "av1", conditions: [
                ProfileCondition(.height, .lessThanEqual, swHeight, isRequired: false),
            ]))
        }
        profile.codecProfiles = codecProfiles
        var subs: [SubtitleProfile] = []
        let embedded = ["srt", "subrip", "ass", "ssa", "vtt", "webvtt", "mov_text", "ttml", "pgssub", "pgs", "dvdsub", "dvbsub", "vobsub", "sub", "microdvd", "smi", "sami"]
        subs.append(contentsOf: embedded.map { SubtitleProfile(format: $0, method: .embed) })
        subs.append(contentsOf: textSubtitleProfiles(method: .external))
        subs.append(contentsOf: textSubtitleProfiles(method: .hls))
        if allowBurnIn { subs.append(contentsOf: burnInSubtitleProfiles()) }
        profile.subtitleProfiles = subs
        return profile
    }
}
