import Foundation
import VelaFoundation
import JellyfinKit

public enum SubtitleMode: String, Sendable, Codable, CaseIterable, Hashable {
    /// Never enable subtitles automatically.
    case off
    /// Only forced subtitles (foreign dialogue in an otherwise understood language).
    case forcedOnly
    /// Forced subtitles when the audio is in a preferred language, full subtitles otherwise (default).
    case smart
    /// Always show subtitles in a preferred language when available.
    case always
}

public struct LanguagePreferences: Sendable, Hashable, Codable {
    /// Ordered by priority, e.g. ["de", "en"].
    public var audioLanguages: [String]
    public var subtitleLanguages: [String]
    public var subtitleMode: SubtitleMode
    /// Prefer tracks flagged for the hearing impaired (SDH/CC) when available.
    public var preferSDH: Bool
    /// Choose the original-language track over the preferred languages.
    public var preferOriginalAudio: Bool

    public init(audioLanguages: [String] = ["de", "en"], subtitleLanguages: [String] = ["de", "en"],
                subtitleMode: SubtitleMode = .smart, preferSDH: Bool = false, preferOriginalAudio: Bool = false) {
        self.audioLanguages = audioLanguages
        self.subtitleLanguages = subtitleLanguages
        self.subtitleMode = subtitleMode
        self.preferSDH = preferSDH
        self.preferOriginalAudio = preferOriginalAudio
    }

    public static let `default` = LanguagePreferences()
}

public struct TrackSelection: Sendable, Hashable {
    public var audioStreamIndex: Int?
    public var subtitleStreamIndex: Int?
    public var reasons: [String]

    public init(audioStreamIndex: Int?, subtitleStreamIndex: Int?, reasons: [String] = []) {
        self.audioStreamIndex = audioStreamIndex
        self.subtitleStreamIndex = subtitleStreamIndex
        self.reasons = reasons
    }
}

/// Picks the initial audio and subtitle tracks according to the user's language rules.
public enum TrackSelector {
    public static func select(streams: [MediaStream], preferences prefs: LanguagePreferences,
                              rememberedAudioLanguage: String? = nil) -> TrackSelection {
        let audioTracks = streams.filter { $0.isAudio }
        let subtitleTracks = streams.filter { $0.isSubtitle }
        var reasons: [String] = []

        let audio = selectAudio(audioTracks, prefs: prefs, remembered: rememberedAudioLanguage, reasons: &reasons)
        let subtitle = selectSubtitle(subtitleTracks, audio: audio, prefs: prefs, reasons: &reasons)
        return TrackSelection(audioStreamIndex: audio?.index, subtitleStreamIndex: subtitle?.index, reasons: reasons)
    }

    // MARK: Audio

    static func selectAudio(_ tracks: [MediaStream], prefs: LanguagePreferences, remembered: String?, reasons: inout [String]) -> MediaStream? {
        guard !tracks.isEmpty else { return nil }
        if tracks.count == 1 {
            reasons.append("audio: only one track")
            return tracks[0]
        }

        let candidates = tracks.filter { !$0.isCommentary }.isEmpty ? tracks : tracks.filter { !$0.isCommentary }

        if let remembered, let match = best(candidates.filter { LanguageCode.matches($0.language, remembered) }) {
            reasons.append("audio: \(LanguageCode.displayName(remembered) ?? remembered) (last used for this series)")
            return match
        }

        if prefs.preferOriginalAudio, let original = best(candidates.filter { $0.isOriginal == true }) {
            reasons.append("audio: original language")
            return original
        }

        for language in prefs.audioLanguages {
            if let match = best(candidates.filter { LanguageCode.matches($0.language, language) }) {
                reasons.append("audio: \(LanguageCode.displayName(language) ?? language) preferred")
                return match
            }
        }

        if let original = best(candidates.filter { $0.isOriginal == true }) {
            reasons.append("audio: original language (no preferred language available)")
            return original
        }
        if let flagged = best(candidates.filter { $0.isDefault == true }) {
            reasons.append("audio: default track")
            return flagged
        }
        reasons.append("audio: first track")
        return best(candidates) ?? tracks[0]
    }

    /// Prefers default-flagged tracks, then more channels, then lossless/object formats, then lower index.
    static func best(_ tracks: [MediaStream]) -> MediaStream? {
        tracks.max { lhs, rhs in
            score(lhs) < score(rhs)
        }
    }

    private static func score(_ track: MediaStream) -> Int {
        var s = 0
        if track.isDefault == true { s += 1000 }
        s += min(track.channels ?? 2, 8) * 10
        switch track.normalizedCodec {
        case "truehd", "flac", "alac", "pcm_s24le", "pcm_s16le": s += 6
        case "dts": s += track.normalizedProfile.contains("ma") ? 6 : 3
        case "eac3": s += track.isObjectAudio ? 5 : 4
        case "ac3": s += 3
        default: s += 2
        }
        // Prefer lower indices on ties.
        s -= min(track.index, 99)
        return s
    }

    // MARK: Subtitles

    static func selectSubtitle(_ tracks: [MediaStream], audio: MediaStream?, prefs: LanguagePreferences, reasons: inout [String]) -> MediaStream? {
        guard !tracks.isEmpty, prefs.subtitleMode != .off else {
            if prefs.subtitleMode == .off { reasons.append("subtitles: off by preference") }
            return nil
        }

        let audioLanguage = audio?.normalizedLanguage
        let primaryAudio = prefs.audioLanguages.first.flatMap { LanguageCode.normalize($0) }
        // Unknown audio language: assume the user understands it, avoid forcing subtitles on.
        let audioIsUnderstood: Bool = {
            guard let audioLanguage else { return true }
            return prefs.audioLanguages.contains { LanguageCode.matches($0, audioLanguage) }
                && (primaryAudio == nil || LanguageCode.matches(primaryAudio, audioLanguage) || prefs.subtitleMode != .smart)
        }()

        func forced(in language: String?) -> MediaStream? {
            let forcedTracks = tracks.filter { $0.isForced == true }
            guard !forcedTracks.isEmpty else { return nil }
            if let language, let match = forcedTracks.first(where: { LanguageCode.matches($0.language, language) }) { return match }
            for pref in prefs.subtitleLanguages {
                if let match = forcedTracks.first(where: { LanguageCode.matches($0.language, pref) }) { return match }
            }
            return language == nil ? forcedTracks.first : nil
        }

        func full(in languages: [String]) -> MediaStream? {
            for language in languages {
                let inLanguage = tracks.filter { LanguageCode.matches($0.language, language) && $0.isForced != true }
                guard !inLanguage.isEmpty else { continue }
                let sdh = inLanguage.filter { $0.isSDH }
                let regular = inLanguage.filter { !$0.isSDH }
                let pool = prefs.preferSDH ? (sdh.isEmpty ? regular : sdh) : (regular.isEmpty ? sdh : regular)
                let pick = pool.first { $0.isDefault == true } ?? pool.first { $0.isExternal != true } ?? pool.first
                // Jellyfin reads the whole file to extract an embedded text track (an hour for a 50 GB remux on a
                // slow disk, starving the video stream meanwhile); an external file in the same language loads at once.
                if let pick, pick.isExternal != true, pick.isTextSubtitle,
                   let external = (pool + inLanguage).first(where: { $0.isExternal == true && $0.isTextSubtitle }) {
                    return external
                }
                return pick
            }
            return nil
        }

        switch prefs.subtitleMode {
        case .off:
            return nil
        case .forcedOnly:
            if let track = forced(in: audioLanguage) {
                reasons.append("subtitles: forced track")
                return track
            }
            reasons.append("subtitles: none (forced only)")
            return nil
        case .always:
            if let track = full(in: prefs.subtitleLanguages) {
                reasons.append("subtitles: \(LanguageCode.displayName(track.language) ?? "preferred language") always on")
                return track
            }
            if let track = forced(in: audioLanguage) {
                reasons.append("subtitles: forced track")
                return track
            }
            reasons.append("subtitles: none available in preferred languages")
            return nil
        case .smart:
            if audioIsUnderstood {
                if let track = forced(in: audioLanguage) {
                    reasons.append("subtitles: forced track for \(LanguageCode.displayName(audioLanguage) ?? "audio language") audio")
                    return track
                }
                reasons.append("subtitles: none needed (audio in preferred language)")
                return nil
            }
            // Audio is not in the primary language (e.g. original/English): show full subtitles.
            let ranked = prefs.subtitleLanguages.filter { !LanguageCode.matches($0, audioLanguage) } + prefs.subtitleLanguages
            if let track = full(in: ranked) {
                reasons.append("subtitles: \(LanguageCode.displayName(track.language) ?? "preferred language") because audio is \(LanguageCode.displayName(audioLanguage) ?? "not preferred")")
                return track
            }
            if let track = forced(in: audioLanguage) {
                reasons.append("subtitles: forced track")
                return track
            }
            reasons.append("subtitles: none available in preferred languages")
            return nil
        }
    }
}
