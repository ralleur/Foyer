import Foundation
import VelaFoundation
import JellyfinKit

extension AppEnvironment {
    /// Presents the player for an item. Safe to call from any screen. Stream indices come from
    /// remote-control requests; `-1` for subtitles means off, nil leaves the choice to the language rules.
    func play(_ item: BaseItem, mediaSourceId: String? = nil, start: PlaybackStart, audioStreamIndex: Int? = nil, subtitleStreamIndex: Int? = nil) {
        guard let client else { return }
        guard item.isPlayable || item.isEpisode || item.isMovie else {
            Log.warning(.ui, "Attempted to play non-playable item \(item.id) (\(item.type?.rawValue ?? "?"))")
            return
        }
        if let existing = playback {
            existing.close()
        }
        let coordinator = PlaybackCoordinator(item: item, mediaSourceId: mediaSourceId, start: start, client: client,
                                              preferences: preferences, capabilities: capabilities, images: images)
        coordinator.preferredAudioStreamIndex = audioStreamIndex
        coordinator.preferredSubtitleStreamIndex = subtitleStreamIndex
        coordinator.onClose = { [weak self, weak coordinator] in
            guard let self, let coordinator, self.playback === coordinator else { return }
            self.playback = nil
        }
        playback = coordinator
        Log.info(.ui, "Opening player for '\(item.displayTitle)' (\(item.id))")
    }

    /// Marks an item watched/unwatched and returns the updated item for local UI refresh.
    @discardableResult
    func setPlayed(_ item: BaseItem, played: Bool) async -> BaseItem? {
        guard let client else { return nil }
        do {
            let data = try await client.markPlayed(itemId: item.id, played: played)
            var updated = item
            updated.userData = data
            return updated
        } catch {
            Log.warning(.jellyfin, "Mark played failed: \(VelaError.wrap(error))")
            return nil
        }
    }
}
