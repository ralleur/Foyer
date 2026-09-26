import Foundation
import JellyfinKit

public enum PlaybackEngineKind: String, Sendable, Codable, Hashable {
    case native
    case advanced

    public var displayName: String {
        switch self {
        case .native: "Native"
        case .advanced: "Advanced"
        }
    }
}

public enum PlaybackMethod: String, Sendable, Codable, Hashable {
    case directPlay
    case directStream
    case transcode

    public var jellyfinPlayMethod: PlayMethod {
        switch self {
        case .directPlay: .directPlay
        case .directStream: .directStream
        case .transcode: .transcode
        }
    }

    public var displayName: String {
        switch self {
        case .directPlay: "Direct Play"
        case .directStream: "Direct Stream"
        case .transcode: "Transcode"
        }
    }
}

public enum PlaybackRoute: String, Sendable, Codable, Hashable {
    case nativeDirectPlay
    case advancedDirectPlay
    case directStream
    case transcode

    public var engine: PlaybackEngineKind {
        switch self {
        case .advancedDirectPlay: .advanced
        default: .native
        }
    }

    public var method: PlaybackMethod {
        switch self {
        case .nativeDirectPlay, .advancedDirectPlay: .directPlay
        case .directStream: .directStream
        case .transcode: .transcode
        }
    }

    public var displayName: String {
        switch self {
        case .nativeDirectPlay: "Native Direct Play"
        case .advancedDirectPlay: "Advanced Direct Play"
        case .directStream: "Direct Stream"
        case .transcode: "Transcode"
        }
    }
}

/// How the selected subtitle track reaches the screen.
public enum SubtitleHandling: Sendable, Hashable, Codable {
    case none
    /// The engine renders the track from the container (mpv, or tx3g in AVFoundation).
    case embedded
    /// Foyer downloads the text track and draws it in its own overlay.
    case externalText
    /// The server burns the subtitle into the video (transcode).
    case burnIn
}

public struct PlaybackDecision: Sendable, Hashable {
    public var route: PlaybackRoute
    public var audioStreamIndex: Int?
    public var subtitleStreamIndex: Int?
    public var subtitleHandling: SubtitleHandling
    public var deviceProfile: DeviceProfile
    public var enableDirectPlay: Bool
    public var enableDirectStream: Bool
    public var enableTranscoding: Bool
    /// Ordered, human readable justification for the debug screen and logs.
    public var reasons: [String]
    public var compromises: [String]

    public var engine: PlaybackEngineKind { route.engine }
    public var method: PlaybackMethod { route.method }

    public var summary: String {
        var lines = [route.displayName]
        lines.append(contentsOf: reasons.map { "• " + $0 })
        if !compromises.isEmpty {
            lines.append("Compromises:")
            lines.append(contentsOf: compromises.map { "• " + $0 })
        }
        return lines.joined(separator: "\n")
    }
}

/// Decides how a media source should be played *before* asking the server,
/// then tailors the device profile so the server agrees. The server response
/// is reconciled afterwards by `PlaybackDecisionEngine.reconcile`.
public struct PlaybackDecisionEngine: Sendable {
    public var capabilities: DeviceCapabilities
    public var preferences: PlaybackPreferences

    public init(capabilities: DeviceCapabilities, preferences: PlaybackPreferences = .default) {
        self.capabilities = capabilities
        self.preferences = preferences
    }

    public func decide(source: MediaSource, audioStreamIndex: Int?, subtitleStreamIndex: Int?) -> PlaybackDecision {
        let video = source.videoStream
        let audio = source.stream(index: audioStreamIndex) ?? source.audioStreams.first
        let subtitle = source.stream(index: subtitleStreamIndex)
        let caps = capabilities
        let prefs = preferences

        let advancedAllowed = caps.advancedEngineAvailable && prefs.advancedEngineMode != .never
        let native = NativeCapability.check(source: source, video: video, audio: audio, subtitle: subtitle, capabilities: caps)
        let advanced = advancedAllowed
            ? AdvancedCapability.check(source: source, video: video, audio: audio, subtitle: subtitle, capabilities: caps)
            : .unavailable

        let serverDirectPlay = source.supportsDirectPlay ?? true
        let serverDirectStream = source.supportsDirectStream ?? true
        let serverTranscode = source.supportsTranscoding ?? true
        let isHDR = video?.isHDR ?? false
        let selectedSubtitleIsBitmap = subtitle?.isBitmapSubtitle ?? false

        var reasons: [String] = []
        var compromises: [String] = []

        func subtitleHandling(for route: PlaybackRoute) -> SubtitleHandling {
            guard let subtitle else { return .none }
            switch route {
            case .advancedDirectPlay:
                return subtitle.isExternal == true && subtitle.isTextSubtitle ? .externalText : .embedded
            case .nativeDirectPlay, .directStream:
                if subtitle.isTextSubtitle {
                    return subtitle.normalizedCodec == "mov_text" && subtitle.isExternal != true ? .embedded : .externalText
                }
                return prefs.allowBurnInSubtitles ? .burnIn : .none
            case .transcode:
                return subtitle.isTextSubtitle ? .externalText : (prefs.allowBurnInSubtitles ? .burnIn : .none)
            }
        }

        func finish(_ route: PlaybackRoute, extra: [String] = []) -> PlaybackDecision {
            let handling = subtitleHandling(for: route)
            var finalRoute = route
            if handling == .burnIn, route == .directStream {
                finalRoute = .transcode
                reasons.append("bitmap subtitles are burned in by the server (video re-encode)")
            }
            let profile = DeviceProfileBuilder(capabilities: caps, preferences: prefs)
                .profile(for: finalRoute.engine, allowBurnIn: handling == .burnIn)
            let forced = prefs.directPlayMode == .forced
            return PlaybackDecision(
                route: finalRoute,
                audioStreamIndex: audio?.index,
                subtitleStreamIndex: subtitle?.index,
                subtitleHandling: handling,
                deviceProfile: profile,
                enableDirectPlay: true,
                enableDirectStream: !forced,
                enableTranscoding: !forced,
                reasons: reasons + extra,
                compromises: compromises
            )
        }

        // 1. Native direct play is the best case: hardware decode, HDR/DV, passthrough, no server work.
        if native.canDirectPlay, serverDirectPlay, prefs.advancedEngineMode != .always {
            reasons.append(contentsOf: native.notes)
            reasons.append("no server transcoding required")
            compromises.append(contentsOf: native.compromises)
            return finish(.nativeDirectPlay)
        }

        // 2. Advanced engine direct play.
        if advanced.canDirectPlay, serverDirectPlay {
            let remuxKeepsHDR = isHDR && !caps.advancedEngineSupportsHDROutput && prefs.preferHDRPicture
                && prefs.directPlayMode != .forced && serverDirectStream && prefs.advancedEngineMode != .always
                && NativeCapability.videoCompatibleAfterRemux(video, caps: caps)
                && !selectedSubtitleIsBitmap
            if remuxKeepsHDR {
                reasons.append("\(video?.effectiveVideoRange.displayName ?? "HDR") is preserved by the system player after a server remux (no video re-encode)")
                if !native.audioOK, let audio {
                    reasons.append("\(audio.technicalLabel) is converted by the server (audio only)")
                    compromises.append("\(audio.technicalLabel) becomes E-AC-3/AAC")
                }
                reasons.append("advanced engine would tone-map HDR to SDR on tvOS")
                if !native.containerOK { reasons.append("\(source.container ?? "container") repackaged to fMP4/HLS") }
                return finish(.directStream)
            }
            reasons.append(contentsOf: advanced.notes)
            if !native.canDirectPlay {
                reasons.append("system player cannot play this directly: " + native.blockers.joined(separator: "; "))
            }
            reasons.append("no server transcoding required")
            compromises.append(contentsOf: advanced.compromises)
            return finish(.advancedDirectPlay)
        }

        // 2b. Advanced engine forced on but capability check failed: fall back to native if it can.
        if native.canDirectPlay, serverDirectPlay {
            reasons.append(contentsOf: native.notes)
            if advancedAllowed { reasons.append("advanced engine cannot play this: " + advanced.blockers.joined(separator: "; ")) }
            return finish(.nativeDirectPlay)
        }

        // 3. Forced direct play: try anyway with the most capable engine.
        if prefs.directPlayMode == .forced {
            reasons.append("direct play forced by settings; server assistance disabled")
            if advancedAllowed, advanced.containerOK {
                reasons.append(contentsOf: advanced.blockers.map { "unverified: " + $0 })
                return finish(.advancedDirectPlay)
            }
            reasons.append(contentsOf: native.blockers.map { "unverified: " + $0 })
            return finish(.nativeDirectPlay)
        }

        // 4. Server assisted. Prefer a remux (video copy) when the elementary video stream is fine.
        let videoRemuxable = NativeCapability.videoCompatibleAfterRemux(video, caps: caps)
        if !native.canDirectPlay { reasons.append("system player: " + native.blockers.joined(separator: "; ")) }
        if advancedAllowed, !advanced.canDirectPlay { reasons.append("advanced engine: " + advanced.blockers.joined(separator: "; ")) }
        if videoRemuxable, serverDirectStream {
            reasons.append("video stream copied by the server; only the container\(native.audioOK ? "" : " and audio") change")
            if !native.audioOK, let audio { compromises.append("\(audio.technicalLabel) re-encoded by the server") }
            return finish(.directStream)
        }
        if serverTranscode {
            reasons.append("server transcodes the video")
            compromises.append("video re-encoded by the server")
            return finish(.transcode)
        }
        reasons.append("server does not allow transcoding for this item")
        return finish(.transcode)
    }

    /// Adjusts the decision after the server answered `PlaybackInfo`.
    /// The server has the final word on whether a direct stream is possible.
    public func reconcile(_ decision: PlaybackDecision, with server: MediaSource) -> PlaybackDecision {
        var result = decision
        var extra: [String] = []
        let serverSaysDirectPlay = server.supportsDirectPlay ?? false
        let hasTranscodingURL = !(server.transcodingUrl ?? "").isEmpty

        switch decision.route {
        case .nativeDirectPlay, .advancedDirectPlay:
            if !serverSaysDirectPlay {
                if hasTranscodingURL {
                    let method = (server.supportsDirectStream ?? false) && !(server.transcodingUrl ?? "").lowercased().contains("videocodec=") ? PlaybackRoute.directStream : .transcode
                    result.route = method
                    extra.append("server declined direct play; using its \(method.displayName.lowercased()) stream")
                } else {
                    extra.append("server reports no direct play support but offered no alternative; attempting direct play anyway")
                }
            }
        case .directStream:
            if hasTranscodingURL {
                if (server.transcodingUrl ?? "").lowercased().contains("videocodec=") && !(server.supportsDirectStream ?? true) {
                    result.route = .transcode
                    extra.append("server needs to re-encode the video")
                }
            } else if serverSaysDirectPlay {
                // Server thinks the file itself is fine for our profile; trust it.
                result.route = .nativeDirectPlay
                extra.append("server offers the original file for direct play")
            }
        case .transcode:
            if !hasTranscodingURL, serverSaysDirectPlay {
                result.route = .nativeDirectPlay
                extra.append("server offers the original file for direct play")
            }
        }

        if result.route != decision.route {
            result.subtitleHandling = result.route == .advancedDirectPlay ? .embedded : decision.subtitleHandling
        }
        if let audio = server.defaultAudioStreamIndex, result.audioStreamIndex == nil { result.audioStreamIndex = audio }
        result.reasons.append(contentsOf: extra)
        return result
    }
}
