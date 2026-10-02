import Foundation
import Observation
import VelaFoundation
import JellyfinKit
import PlaybackDecision

@MainActor
@Observable
final class SeriesViewModel {
    let seriesId: String
    private(set) var series: BaseItem?
    private(set) var seasons: [BaseItem] = []
    private(set) var episodesBySeason: [String: [BaseItem]] = [:]
    private(set) var nextUp: BaseItem?
    private(set) var isLoading = false
    private(set) var loadingSeasonId: String?
    private(set) var error: (any Error)?
    var selectedSeasonId: String? {
        didSet { if let id = selectedSeasonId, episodesBySeason[id] == nil { Task { await loadEpisodes(seasonId: id) } } }
    }
    private var client: JellyfinClient?

    init(seriesId: String, initialSeries: BaseItem?, initialSeasonId: String?) {
        self.seriesId = seriesId
        self.series = initialSeries
        self.selectedSeasonId = initialSeasonId
    }

    var selectedEpisodes: [BaseItem] {
        guard let id = selectedSeasonId else { return [] }
        return episodesBySeason[id] ?? []
    }

    /// The episode the primary button plays: resumable/next-up episode, else first unwatched, else first.
    var primaryEpisode: BaseItem? {
        if let nextUp { return nextUp }
        for season in seasons {
            if let episodes = episodesBySeason[season.id], let unwatched = episodes.first(where: { !$0.isPlayed }) {
                return unwatched
            }
        }
        return seasons.first.flatMap { episodesBySeason[$0.id]?.first }
    }

    var primaryActionTitle: String? {
        guard let episode = primaryEpisode else { return nil }
        let label = episode.episodeLabel ?? episode.displayTitle
        if ResumePolicy.canResume(episode) { return L10n.continueEpisode(label) }
        if nextUp == nil, seasons.allSatisfy({ ($0.userData?.unplayedItemCount ?? 1) == 0 }), !seasons.isEmpty {
            return L10n.playEpisode(label)
        }
        return L10n.playEpisode(label)
    }

    var allWatched: Bool {
        !seasons.isEmpty && seasons.allSatisfy { ($0.userData?.unplayedItemCount ?? 1) == 0 }
    }

    func load(client: JellyfinClient) async {
        self.client = client
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        async let seriesItem = client.item(id: seriesId)
        async let seasonItems = client.seasons(seriesId: seriesId)
        async let nextUpItems = (try? await client.nextUp(limit: 1, seriesId: seriesId)) ?? []
        do {
            series = try await seriesItem
            let fetchedSeasons = try await seasonItems
            seasons = fetchedSeasons.sorted { ($0.indexNumber ?? 0) < ($1.indexNumber ?? 0) }
            let next = await nextUpItems.first
            nextUp = next
            error = nil
            if selectedSeasonId == nil || !seasons.contains(where: { $0.id == selectedSeasonId }) {
                selectedSeasonId = next?.seasonId ?? seasons.first(where: { ($0.indexNumber ?? 0) > 0 })?.id ?? seasons.first?.id
            } else if let id = selectedSeasonId, episodesBySeason[id] == nil {
                await loadEpisodes(seasonId: id)
            }
        } catch {
            self.error = error
            Log.error(.jellyfin, "Loading series \(seriesId) failed: \(VelaError.wrap(error))")
        }
    }

    func loadEpisodes(seasonId: String) async {
        guard let client, loadingSeasonId != seasonId else { return }
        loadingSeasonId = seasonId
        defer { if loadingSeasonId == seasonId { loadingSeasonId = nil } }
        do {
            let episodes = try await client.episodes(seriesId: seriesId, seasonId: seasonId)
            episodesBySeason[seasonId] = episodes
        } catch {
            Log.error(.jellyfin, "Loading episodes failed: \(VelaError.wrap(error))")
            if episodesBySeason[seasonId] == nil { self.error = error }
        }
    }

    func refreshAfterPlayback() async {
        guard let client else { return }
        nextUp = (try? await client.nextUp(limit: 1, seriesId: seriesId))?.first
        if let id = selectedSeasonId {
            loadingSeasonId = nil
            await loadEpisodes(seasonId: id)
        }
        if let fresh = try? await client.seasons(seriesId: seriesId) {
            seasons = fresh.sorted { ($0.indexNumber ?? 0) < ($1.indexNumber ?? 0) }
        }
    }

    func togglePlayed(_ episode: BaseItem) async {
        guard let client else { return }
        let target = !episode.isPlayed
        do {
            let data = try await client.markPlayed(itemId: episode.id, played: target)
            if let seasonId = episode.seasonId, var list = episodesBySeason[seasonId], let index = list.firstIndex(where: { $0.id == episode.id }) {
                list[index].userData = data
                episodesBySeason[seasonId] = list
            }
            await refreshAfterPlayback()
        } catch {
            Log.warning(.jellyfin, "Toggling episode played failed: \(VelaError.wrap(error))")
        }
    }

    func seasonTitle(_ season: BaseItem) -> String {
        if let index = season.indexNumber {
            return index == 0 ? L10n.specials : L10n.season(index)
        }
        return season.displayTitle
    }
}
