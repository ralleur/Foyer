import Foundation
import JellyfinKit

/// What the Apple TV home screen shows above Vela's tile: "Continue Watching" and "Recently Added".
/// Built from Jellyfin items, stored in the shared App Group container and turned into
/// `TVTopShelfSectionedContent` by the Top Shelf extension.
public struct TopShelfSnapshot: Codable, Hashable, Sendable {
    public struct Entry: Codable, Hashable, Sendable {
        public var id: String
        public var title: String
        public var imageURL1x: URL?
        public var imageURL2x: URL?
        /// 0...1 for partially watched items, nil otherwise.
        public var progress: Double?
        /// Selecting the item on the home screen.
        public var displayURL: URL
        /// The Play/Pause button; nil when the item cannot be played directly (series).
        public var playURL: URL?
    }

    public struct Section: Codable, Hashable, Sendable {
        public enum Kind: String, Codable, Sendable {
            case continueWatching
            case recentlyAdded
        }

        public enum Shape: String, Codable, Sendable {
            case landscape
            case poster
        }

        public var kind: Kind
        public var shape: Shape
        public var entries: [Entry]
    }

    public var accountId: String
    public var created: Date
    public var sections: [Section]

    public var isEmpty: Bool { sections.allSatisfy(\.entries.isEmpty) }
}

public enum TopShelfBuilder {
    public static let continueLimit = 10
    public static let recentlyAddedLimit = 12

    /// - Parameters:
    ///   - resume: partially watched movies and episodes, most recent first.
    ///   - nextUp: next episodes of series in progress.
    ///   - latest: recently added items, one list per library (interleaved so no library dominates).
    public static func snapshot(accountId: String, resume: [BaseItem], nextUp: [BaseItem], latest: [[BaseItem]],
                                images: ItemImages, now: Date = Date()) -> TopShelfSnapshot {
        var seen = Set<String>()
        var continueEntries: [TopShelfSnapshot.Entry] = []
        for item in resume + nextUp where continueEntries.count < continueLimit && seen.insert(item.id).inserted {
            let progress = item.playedPercentage.map { $0 / 100 }
            continueEntries.append(TopShelfSnapshot.Entry(
                id: item.id, title: title(item),
                imageURL1x: images.landscape(item, width: 560), imageURL2x: images.landscape(item, width: 1120),
                progress: progress, displayURL: VelaLink.play(id: item.id).url, playURL: VelaLink.play(id: item.id).url))
        }

        var latestEntries: [TopShelfSnapshot.Entry] = []
        for item in interleave(latest) where latestEntries.count < recentlyAddedLimit && seen.insert(item.id).inserted {
            let playable = item.isMovie || item.isEpisode
            latestEntries.append(TopShelfSnapshot.Entry(
                id: item.id, title: title(item),
                imageURL1x: images.poster(item, width: 300), imageURL2x: images.poster(item, width: 600),
                progress: nil, displayURL: VelaLink.item(id: item.id).url, playURL: playable ? VelaLink.play(id: item.id).url : nil))
        }

        var sections: [TopShelfSnapshot.Section] = []
        if !continueEntries.isEmpty { sections.append(.init(kind: .continueWatching, shape: .landscape, entries: continueEntries)) }
        if !latestEntries.isEmpty { sections.append(.init(kind: .recentlyAdded, shape: .poster, entries: latestEntries)) }
        return TopShelfSnapshot(accountId: accountId, created: now, sections: sections)
    }

    /// "The Expanse · S1 · E3" for episodes, the plain name otherwise.
    static func title(_ item: BaseItem) -> String {
        if item.isEpisode, let series = item.seriesName {
            return [series, item.episodeLabel].compactMap { $0 }.joined(separator: " · ")
        }
        return item.displayTitle
    }

    /// Round-robin over the lists: first of each, then second of each, …
    static func interleave(_ lists: [[BaseItem]]) -> [BaseItem] {
        var result: [BaseItem] = []
        let longest = lists.map(\.count).max() ?? 0
        for index in 0..<longest {
            for list in lists where index < list.count { result.append(list[index]) }
        }
        return result
    }
}

/// Fetches the Top Shelf directly from the server (used by the extension, which runs without the app).
public enum TopShelfLoader {
    public static func load(client: JellyfinClient, accountId: String) async throws -> TopShelfSnapshot {
        async let resume = client.resumeItems(limit: TopShelfBuilder.continueLimit)
        async let nextUp = try? client.nextUp(limit: TopShelfBuilder.continueLimit)
        async let latest = latestPerLibrary(client: client)
        // Resume is the one request that must work; the others only add rows.
        let (resumeItems, nextUpItems, latestLists) = try await (resume, nextUp, latest)
        return TopShelfBuilder.snapshot(accountId: accountId, resume: resumeItems, nextUp: nextUpItems ?? [], latest: latestLists,
                                        images: ItemImages(client: client))
    }

    /// Same libraries as the app's Home screen: movies and shows, at most four.
    private static func latestPerLibrary(client: JellyfinClient) async -> [[BaseItem]] {
        let views = (try? await client.userViews()) ?? []
        let libraries = (views.filter { $0.collectionType == .movies } + views.filter { $0.collectionType == .tvshows }).prefix(4)
        return await withTaskGroup(of: (Int, [BaseItem]).self) { group in
            for (index, library) in libraries.enumerated() {
                group.addTask { (index, (try? await client.latest(parentId: library.id, limit: TopShelfBuilder.recentlyAddedLimit)) ?? []) }
            }
            var results: [(Int, [BaseItem])] = []
            for await result in group { results.append(result) }
            return results.sorted { $0.0 < $1.0 }.map(\.1)
        }
    }
}

/// Shared state between the app and the Top Shelf extension, stored in the App Group's user defaults
/// (tvOS keeps no files outside Caches on a real device). Holds no secrets: the access token stays in
/// the shared Keychain.
public struct TopShelfStore: @unchecked Sendable {
    /// The signed-in account the extension should load for.
    public struct Account: Codable, Hashable, Sendable {
        public var accountId: String
        public var serverURL: URL
        public var userId: String
        /// Keychain key of the access token.
        public var tokenKey: String
        /// The app's Jellyfin device id and name, so the server sees one device, not two.
        public var deviceId: String
        public var deviceName: String
        public var clientVersion: String

        public init(accountId: String, serverURL: URL, userId: String, tokenKey: String, deviceId: String, deviceName: String, clientVersion: String) {
            self.accountId = accountId
            self.serverURL = serverURL
            self.userId = userId
            self.tokenKey = tokenKey
            self.deviceId = deviceId
            self.deviceName = deviceName
            self.clientVersion = clientVersion
        }

        public var identity: DeviceIdentity {
            DeviceIdentity(deviceName: deviceName, deviceId: deviceId, version: clientVersion)
        }
    }

    private let defaults: UserDefaults
    private let accountKey = "vela.topshelf.account"
    private let snapshotKey = "vela.topshelf.snapshot"

    public init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    public func loadAccount() -> Account? { read(Account.self, key: accountKey) }

    /// Replaces the account; a different (or no) account also drops the old snapshot.
    public func saveAccount(_ account: Account?) {
        guard let account else {
            defaults.removeObject(forKey: accountKey)
            defaults.removeObject(forKey: snapshotKey)
            return
        }
        if loadAccount()?.accountId != account.accountId { defaults.removeObject(forKey: snapshotKey) }
        write(account, key: accountKey)
    }

    /// The last snapshot, only if it belongs to the stored account.
    public func loadSnapshot() -> TopShelfSnapshot? {
        guard let account = loadAccount(), let snapshot = read(TopShelfSnapshot.self, key: snapshotKey),
              snapshot.accountId == account.accountId else { return nil }
        return snapshot
    }

    public func saveSnapshot(_ snapshot: TopShelfSnapshot) {
        write(snapshot, key: snapshotKey)
    }

    private func read<T: Decodable>(_ type: T.Type, key: String) -> T? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    private func write(_ value: some Encodable, key: String) {
        if let data = try? JSONEncoder().encode(value) { defaults.set(data, forKey: key) }
    }
}
