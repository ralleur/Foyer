import Foundation
import VelaFoundation

public extension JellyfinClient {
    private func userQuery(_ extra: [URLQueryItem] = []) throws -> [URLQueryItem] {
        [URLQueryItem(name: "userId", value: try requireUserId())] + extra
    }

    private static func csv(_ fields: [ItemField]) -> String { fields.map(\.rawValue).joined(separator: ",") }
    private static func csv(_ kinds: [BaseItemKind]) -> String { kinds.map(\.rawValue).joined(separator: ",") }
    private static func csv(_ types: [ImageType]) -> String { types.map(\.rawValue).joined(separator: ",") }

    /// The user's libraries (Movies, Shows, Collections, ...).
    func userViews() async throws -> [BaseItem] {
        let uid = try requireUserId()
        let result: QueryResult<BaseItem> = try await withLegacyFallback {
            try await send(.get("/UserViews", query: [URLQueryItem(name: "userId", value: uid)]))
        } fallback: {
            try await send(.get("/Users/\(uid)/Views"))
        }
        return result.items
    }

    func items(_ query: ItemsQuery) async throws -> QueryResult<BaseItem> {
        let uid = try requireUserId()
        var q = query.queryItems
        q.append(URLQueryItem(name: "userId", value: uid))
        return try await send(.get("/Items", query: q))
    }

    func item(id: String, fields: [ItemField] = ItemField.detail) async throws -> BaseItem {
        let uid = try requireUserId()
        let fieldItems = [URLQueryItem(name: "fields", value: Self.csv(fields))]
        return try await withLegacyFallback {
            try await send(.get("/Items/\(id)", query: [URLQueryItem(name: "userId", value: uid)] + fieldItems))
        } fallback: {
            try await send(.get("/Users/\(uid)/Items/\(id)", query: fieldItems))
        }
    }

    /// "Continue watching" – partially watched movies and episodes.
    func resumeItems(limit: Int = 20) async throws -> [BaseItem] {
        let uid = try requireUserId()
        let query = [
            URLQueryItem(name: "limit", value: String(limit)),
            URLQueryItem(name: "mediaTypes", value: "Video"),
            URLQueryItem(name: "includeItemTypes", value: Self.csv([.movie, .episode])),
            URLQueryItem(name: "fields", value: Self.csv(ItemField.card + [.overview, .mediaSourceCount])),
            URLQueryItem(name: "enableImageTypes", value: Self.csv([.primary, .backdrop, .thumb, .logo])),
            URLQueryItem(name: "imageTypeLimit", value: "1"),
            URLQueryItem(name: "enableTotalRecordCount", value: "false"),
        ]
        let result: QueryResult<BaseItem> = try await withLegacyFallback {
            try await send(.get("/UserItems/Resume", query: [URLQueryItem(name: "userId", value: uid)] + query))
        } fallback: {
            try await send(.get("/Users/\(uid)/Items/Resume", query: query))
        }
        return result.items
    }

    /// "Next up" episodes for series in progress.
    func nextUp(limit: Int = 20, seriesId: String? = nil) async throws -> [BaseItem] {
        var query = try userQuery([
            URLQueryItem(name: "limit", value: String(limit)),
            URLQueryItem(name: "fields", value: Self.csv(ItemField.card + [.overview])),
            URLQueryItem(name: "enableImageTypes", value: Self.csv([.primary, .backdrop, .thumb, .logo])),
            URLQueryItem(name: "imageTypeLimit", value: "1"),
            URLQueryItem(name: "enableTotalRecordCount", value: "false"),
            URLQueryItem(name: "enableResumable", value: "false"),
            URLQueryItem(name: "enableRewatching", value: "false"),
        ])
        if let seriesId {
            query.append(URLQueryItem(name: "seriesId", value: seriesId))
        }
        let result: QueryResult<BaseItem> = try await send(.get("/Shows/NextUp", query: query))
        return result.items
    }

    /// Recently added items in a library.
    func latest(parentId: String?, limit: Int = 16, includeItemTypes: [BaseItemKind] = []) async throws -> [BaseItem] {
        let uid = try requireUserId()
        var query = [
            URLQueryItem(name: "limit", value: String(limit)),
            URLQueryItem(name: "fields", value: Self.csv(ItemField.card)),
            URLQueryItem(name: "enableImageTypes", value: Self.csv([.primary, .backdrop, .thumb, .logo])),
            URLQueryItem(name: "imageTypeLimit", value: "1"),
            URLQueryItem(name: "groupItems", value: "true"),
        ]
        if let parentId { query.append(URLQueryItem(name: "parentId", value: parentId)) }
        if !includeItemTypes.isEmpty { query.append(URLQueryItem(name: "includeItemTypes", value: Self.csv(includeItemTypes))) }
        return try await withLegacyFallback {
            try await send(.get("/Items/Latest", query: [URLQueryItem(name: "userId", value: uid)] + query))
        } fallback: {
            try await send(.get("/Users/\(uid)/Items/Latest", query: query))
        }
    }

    func seasons(seriesId: String) async throws -> [BaseItem] {
        let query = try userQuery([
            URLQueryItem(name: "fields", value: Self.csv(ItemField.card + [.overview])),
            URLQueryItem(name: "enableImageTypes", value: Self.csv([.primary, .backdrop, .thumb])),
        ])
        let result: QueryResult<BaseItem> = try await send(.get("/Shows/\(seriesId)/Seasons", query: query))
        return result.items
    }

    func episodes(seriesId: String, seasonId: String?, fields: [ItemField] = ItemField.card + [.overview, .mediaSourceCount]) async throws -> [BaseItem] {
        var query = try userQuery([
            URLQueryItem(name: "fields", value: Self.csv(fields)),
            URLQueryItem(name: "enableImageTypes", value: Self.csv([.primary, .backdrop, .thumb])),
            URLQueryItem(name: "imageTypeLimit", value: "1"),
        ])
        if let seasonId { query.append(URLQueryItem(name: "seasonId", value: seasonId)) }
        let result: QueryResult<BaseItem> = try await send(.get("/Shows/\(seriesId)/Episodes", query: query))
        return result.items
    }

    func similar(itemId: String, limit: Int = 12) async throws -> [BaseItem] {
        let query = try userQuery([
            URLQueryItem(name: "limit", value: String(limit)),
            URLQueryItem(name: "fields", value: Self.csv(ItemField.card)),
        ])
        let result: QueryResult<BaseItem> = try await send(.get("/Items/\(itemId)/Similar", query: query))
        return result.items
    }

    func search(term: String, limit: Int = 40, kinds: [BaseItemKind] = [.movie, .series, .episode]) async throws -> [BaseItem] {
        var query = ItemsQuery(includeItemTypes: kinds, sortBy: [], limit: limit)
        query.searchTerm = term
        query.recursive = true
        query.enableTotalRecordCount = false
        query.fields = ItemField.card
        return try await items(query).items
    }

    // MARK: Watch state

    @discardableResult
    /// Sets position and played flag directly (`POST /UserItems/{id}/UserData`, Jellyfin 10.10+). Used by the
    /// self-test to put an item's watch state back after playing it.
    func updateUserData(itemId: String, positionTicks: Int64, played: Bool) async throws {
        struct Body: Encodable {
            let playbackPositionTicks: Int64
            let played: Bool
            enum CodingKeys: String, CodingKey { case playbackPositionTicks = "PlaybackPositionTicks", played = "Played" }
        }
        _ = try await send(try Endpoint.post("/UserItems/\(itemId)/UserData", json: Body(playbackPositionTicks: positionTicks, played: played)))
    }

    func markPlayed(itemId: String, played: Bool) async throws -> UserData {
        let uid = try requireUserId()
        return try await withLegacyFallback {
            if played {
                return try await send(try Endpoint.post("/UserPlayedItems/\(itemId)", query: [URLQueryItem(name: "userId", value: uid)]))
            } else {
                return try await send(.delete("/UserPlayedItems/\(itemId)", query: [URLQueryItem(name: "userId", value: uid)]))
            }
        } fallback: {
            if played {
                return try await send(try Endpoint.post("/Users/\(uid)/PlayedItems/\(itemId)"))
            } else {
                return try await send(.delete("/Users/\(uid)/PlayedItems/\(itemId)"))
            }
        }
    }

    @discardableResult
    func setFavorite(itemId: String, favorite: Bool) async throws -> UserData {
        let uid = try requireUserId()
        return try await withLegacyFallback {
            if favorite {
                return try await send(try Endpoint.post("/UserFavoriteItems/\(itemId)", query: [URLQueryItem(name: "userId", value: uid)]))
            } else {
                return try await send(.delete("/UserFavoriteItems/\(itemId)", query: [URLQueryItem(name: "userId", value: uid)]))
            }
        } fallback: {
            if favorite {
                return try await send(try Endpoint.post("/Users/\(uid)/FavoriteItems/\(itemId)"))
            } else {
                return try await send(.delete("/Users/\(uid)/FavoriteItems/\(itemId)"))
            }
        }
    }
}
