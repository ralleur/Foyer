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
    /// Subtitle choices the user made in the player (see `subtitleChoice(for:)`).
    private(set) var subtitleMemory: SubtitleMemory { didSet { save(subtitleMemory, key: "subtitleMemory") } }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        languages = Self.load(LanguagePreferences.self, key: "languages", defaults: defaults) ?? .default
        playback = Self.load(PlaybackPreferences.self, key: "playback", defaults: defaults) ?? .default
        autoPlayNextEpisode = defaults.object(forKey: "autoPlayNextEpisode") as? Bool ?? true
        subtitleSize = Self.load(SubtitleSize.self, key: "subtitleSize", defaults: defaults) ?? .medium
        showTechnicalBadges = defaults.object(forKey: "showTechnicalBadges") as? Bool ?? true
        debugModeEnabled = defaults.object(forKey: "debugModeEnabled") as? Bool ?? false
        rememberedAudioLanguages = Self.load([String: String].self, key: "rememberedAudioLanguages", defaults: defaults) ?? [:]
        subtitleMemory = Self.load(SubtitleMemory.self, key: "subtitleMemory", defaults: defaults) ?? SubtitleMemory()
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

    /// Remembers a subtitle choice from the player: for this film (or this series) and as the starting point for
    /// the next new film (or series).
    func rememberSubtitle(_ choice: SubtitleChoice, itemId: String, seriesId: String?) {
        var memory = subtitleMemory
        if let seriesId {
            memory.bySeries[seriesId] = choice
            memory.lastSeries = choice
        } else {
            memory.byItem[itemId] = choice
            memory.lastMovie = choice
        }
        memory.trim(to: 500)
        subtitleMemory = memory
    }

    /// The remembered choice for a title: this film's (series') own, else the last one made for any film (series).
    func subtitleChoice(itemId: String, seriesId: String?) -> (choice: SubtitleChoice, source: String)? {
        if let seriesId {
            if let choice = subtitleMemory.bySeries[seriesId] { return (choice, "last choice for this series") }
            return subtitleMemory.lastSeries.map { ($0, "last choice in a series") }
        }
        if let choice = subtitleMemory.byItem[itemId] { return (choice, "last choice for this film") }
        return subtitleMemory.lastMovie.map { ($0, "last choice in a film") }
    }

    func resetForUITests() {
        languages = .default
        playback = .default
        autoPlayNextEpisode = true
        subtitleSize = .medium
        showTechnicalBadges = true
        debugModeEnabled = true
        rememberedAudioLanguages = [:]
        subtitleMemory = SubtitleMemory()
    }
}

struct SubtitleMemory: Codable, Equatable {
    var byItem: [String: SubtitleChoice] = [:]
    var bySeries: [String: SubtitleChoice] = [:]
    var lastMovie: SubtitleChoice?
    var lastSeries: SubtitleChoice?

    /// Keeps the stored dictionaries bounded (dictionary order is arbitrary; any old entry may go).
    mutating func trim(to limit: Int) {
        while byItem.count > limit, let key = byItem.keys.first { byItem.removeValue(forKey: key) }
        while bySeries.count > limit, let key = bySeries.keys.first { bySeries.removeValue(forKey: key) }
    }
}
