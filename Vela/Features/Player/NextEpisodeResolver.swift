import Foundation
import VelaFoundation
import JellyfinKit

/// Finds the episode that follows the current one (across season boundaries).
enum NextEpisodeResolver {
    static func next(after episode: BaseItem, client: JellyfinClient) async -> BaseItem? {
        guard episode.isEpisode, let seriesId = episode.seriesId else { return nil }
        do {
            if let seasonId = episode.seasonId {
                let episodes = try await client.episodes(seriesId: seriesId, seasonId: seasonId, fields: ItemField.card + [.overview, .mediaSources])
                if let index = episodes.firstIndex(where: { $0.id == episode.id }), index + 1 < episodes.count {
                    return episodes[index + 1]
                }
                // Last episode of the season: first episode of the next regular season.
                let seasons = try await client.seasons(seriesId: seriesId).sorted { ($0.indexNumber ?? 0) < ($1.indexNumber ?? 0) }
                if let seasonIndex = seasons.firstIndex(where: { $0.id == seasonId }) {
                    for next in seasons[(seasonIndex + 1)...] where (next.indexNumber ?? 0) > 0 {
                        let nextEpisodes = try await client.episodes(seriesId: seriesId, seasonId: next.id, fields: ItemField.card + [.overview, .mediaSources])
                        if let first = nextEpisodes.first { return first }
                    }
                }
                return nil
            }
            let all = try await client.episodes(seriesId: seriesId, seasonId: nil)
            if let index = all.firstIndex(where: { $0.id == episode.id }), index + 1 < all.count {
                return all[index + 1]
            }
        } catch {
            Log.notice(.jellyfin, "Next episode lookup failed: \(VelaError.wrap(error))")
        }
        return nil
    }

    static func previous(before episode: BaseItem, client: JellyfinClient) async -> BaseItem? {
        guard episode.isEpisode, let seriesId = episode.seriesId, let seasonId = episode.seasonId else { return nil }
        let episodes = (try? await client.episodes(seriesId: seriesId, seasonId: seasonId)) ?? []
        if let index = episodes.firstIndex(where: { $0.id == episode.id }), index > 0 {
            return episodes[index - 1]
        }
        return nil
    }
}
