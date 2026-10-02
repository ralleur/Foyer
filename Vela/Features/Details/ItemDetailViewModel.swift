import Foundation
import Observation
import VelaFoundation
import JellyfinKit
import PlaybackDecision

/// Detail data for movies, episodes and other playable items.
@MainActor
@Observable
final class ItemDetailViewModel {
    private(set) var item: BaseItem
    private(set) var similar: [BaseItem] = []
    private(set) var series: BaseItem?
    private(set) var isLoading = false
    private(set) var error: (any Error)?
    var selectedMediaSourceId: String?
    private var loadedFull = false

    init(item: BaseItem) {
        self.item = item
        self.selectedMediaSourceId = item.defaultMediaSource?.id
    }

    var selectedSource: MediaSource? { item.mediaSource(id: selectedMediaSourceId) }

    var primaryActionTitle: String {
        if let position = ResumePolicy.resumePosition(for: item) {
            if item.isEpisode, let label = item.episodeLabel { return L10n.continueEpisode(label) }
            return L10n.resumeAt(position.clockString)
        }
        if item.isEpisode, let label = item.episodeLabel { return L10n.playEpisode(label) }
        return L10n.play
    }

    var canResume: Bool { ResumePolicy.canResume(item) }

    func load(client: JellyfinClient, force: Bool = false) async {
        guard !isLoading, force || !loadedFull else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let full = try await client.item(id: item.id)
            item = full
            if selectedMediaSourceId == nil || full.mediaSource(id: selectedMediaSourceId) == nil {
                selectedMediaSourceId = full.defaultMediaSource?.id
            }
            loadedFull = true
            error = nil
        } catch {
            self.error = error
            Log.error(.jellyfin, "Loading item \(item.id) failed: \(VelaError.wrap(error))")
        }
        let itemId = item.id
        let seriesIdToLoad = item.isEpisode ? item.seriesId : nil
        async let similarItems = (try? await client.similar(itemId: itemId, limit: 12)) ?? []
        async let seriesItem: BaseItem? = {
            guard let seriesIdToLoad else { return nil }
            return try? await client.item(id: seriesIdToLoad, fields: [.overview, .genres])
        }()
        similar = await similarItems
        series = await seriesItem
    }

    /// Refreshes watch state only (after playback).
    func refreshUserData(client: JellyfinClient) async {
        if let fresh = try? await client.item(id: item.id) {
            item = fresh
        }
    }

    func togglePlayed(client: JellyfinClient) async {
        let target = !item.isPlayed
        var optimistic = item
        var data = optimistic.userData ?? UserData()
        data.played = target
        if target { data.playbackPositionTicks = 0; data.playedPercentage = 0 }
        optimistic.userData = data
        item = optimistic
        do {
            let updated = try await client.markPlayed(itemId: item.id, played: target)
            item.userData = updated
        } catch {
            Log.warning(.jellyfin, "Toggling played failed: \(VelaError.wrap(error))")
            await refreshUserData(client: client)
        }
    }

    func toggleFavorite(client: JellyfinClient) async {
        let target = !item.isFavorite
        var data = item.userData ?? UserData()
        data.isFavorite = target
        item.userData = data
        do {
            let updated = try await client.setFavorite(itemId: item.id, favorite: target)
            item.userData = updated
        } catch {
            Log.warning(.jellyfin, "Toggling favorite failed: \(VelaError.wrap(error))")
            await refreshUserData(client: client)
        }
    }
}
