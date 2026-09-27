import Foundation
import Observation
import PlaybackDecision

enum SubtitleSize: String, Codable, CaseIterable, Sendable {
    case small, medium, large

    var scale: Double {
        switch self {
        case .small: 0.85
        case .medium: 1.0
        case .large: 1.25
        }
    }
}

/// User settings. Everything here is non-secret and lives in UserDefaults.
@MainActor
@Observable
final class Preferences {
    private let defaults: UserDefaults

    var languages: LanguagePreferences { didSet { save(languages, key: "languages") } }
    var playback: PlaybackPreferences { didSet { save(playback, key: "playback") } }
    var autoPlayNextEpisode: Bool { didSet { defaults.set(autoPlayNextEpisode, forKey: "autoPlayNextEpisode") } }
    var subtitleSize: SubtitleSize { didSet { save(subtitleSize, key: "subtitleSize") } }
    var showTechnicalBadges: Bool { didSet { defaults.set(showTechnicalBadges, forKey: "showTechnicalBadges") } }
    var debugModeEnabled: Bool { didSet { defaults.set(debugModeEnabled, forKey: "debugModeEnabled") } }
    /// Remembered audio language per series ("Remember audio selections" behaviour).
    var rememberedAudioLanguages: [String: String] { didSet { save(rememberedAudioLanguages, key: "rememberedAudioLanguages") } }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        languages = Self.load(LanguagePreferences.self, key: "languages", defaults: defaults) ?? .default
        playback = Self.load(PlaybackPreferences.self, key: "playback", defaults: defaults) ?? .default
        autoPlayNextEpisode = defaults.object(forKey: "autoPlayNextEpisode") as? Bool ?? true
        subtitleSize = Self.load(SubtitleSize.self, key: "subtitleSize", defaults: defaults) ?? .medium
        showTechnicalBadges = defaults.object(forKey: "showTechnicalBadges") as? Bool ?? true
        debugModeEnabled = defaults.object(forKey: "debugModeEnabled") as? Bool ?? false
        rememberedAudioLanguages = Self.load([String: String].self, key: "rememberedAudioLanguages", defaults: defaults) ?? [:]
    }

    private func save<T: Encodable>(_ value: T, key: String) {
        if let data = try? JSONEncoder().encode(value) {
            defaults.set(data, forKey: key)
        }
    }

    private static func load<T: Decodable>(_ type: T.Type, key: String, defaults: UserDefaults) -> T? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    func rememberAudioLanguage(_ language: String?, forSeries seriesId: String?) {
        guard let seriesId, let language else { return }
        rememberedAudioLanguages[seriesId] = language
        if rememberedAudioLanguages.count > 300, let oldest = rememberedAudioLanguages.keys.first {
            rememberedAudioLanguages.removeValue(forKey: oldest)
        }
    }

    func resetForUITests() {
        languages = .default
        playback = .default
        autoPlayNextEpisode = true
        subtitleSize = .medium
        showTechnicalBadges = true
        debugModeEnabled = true
        rememberedAudioLanguages = [:]
    }
}
