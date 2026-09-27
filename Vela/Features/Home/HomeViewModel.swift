import Foundation
import Observation
import VelaFoundation
import JellyfinKit

struct HomeSection: Identifiable, Hashable {
    enum Kind: Hashable {
        case continueWatching
        case nextUp
        case latest(libraryId: String)
        case libraries
        case collections
    }

    let kind: Kind
    let title: String
    var items: [BaseItem]

    var id: Kind { kind }
}

/// Loads the Home sections concurrently and keeps a small on-disk snapshot so the
/// screen renders instantly on the next launch while fresh data is fetched.
@MainActor
@Observable
final class HomeViewModel {
    private(set) var sections: [HomeSection] = []
    private(set) var isLoading = false
    private(set) var error: (any Error)?
    private(set) var lastLoaded: Date?
    private var accountId: String?

    func loadIfNeeded(session: ActiveSession, libraries: LibrariesModel, force: Bool = false) async {
        if accountId != session.account.id {
            accountId = session.account.id
            sections = HomeSnapshot.load(accountId: session.account.id) ?? []
            lastLoaded = nil
        }
        if !force, let lastLoaded, Date().timeIntervalSince(lastLoaded) < 45 { return }
        await load(session: session, libraries: libraries)
    }

    func load(session: ActiveSession, libraries: LibrariesModel) async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        let client = session.client
        if !libraries.loaded { await libraries.load(client: client) }

        async let resume = fetch { try await client.resumeItems(limit: 20) }
        async let nextUp = fetch { try await client.nextUp(limit: 20) }
        let latestTargets = (libraries.movieLibraries + libraries.showLibraries).prefix(4)
        async let latestGroups: [(BaseItem, [BaseItem])] = withTaskGroup(of: (Int, BaseItem, [BaseItem]).self) { group in
            for (index, library) in latestTargets.enumerated() {
                group.addTask {
                    let items = (try? await client.latest(parentId: library.id, limit: 16)) ?? []
                    return (index, library, items)
                }
            }
            var results: [(Int, BaseItem, [BaseItem])] = []
            for await result in group { results.append(result) }
            return results.sorted { $0.0 < $1.0 }.map { ($0.1, $0.2) }
        }
        let collectionLibrary = libraries.collectionLibraries.first
        async let collections: [BaseItem] = {
            guard let library = collectionLibrary else { return [] }
            var query = ItemsQuery(parentId: library.id, includeItemTypes: [.boxSet], sortBy: [.dateCreated], sortOrder: .descending, limit: 16)
            query.recursive = true
            return (try? await client.items(query).items) ?? []
        }()

        let (resumeItems, nextUpItems, latest, collectionItems) = await (resume, nextUp, latestGroups, collections)

        var fresh: [HomeSection] = []
        if let items = resumeItems.value, !items.isEmpty {
            fresh.append(HomeSection(kind: .continueWatching, title: L10n.continueWatching, items: items))
        }
        if let items = nextUpItems.value {
            // Avoid showing an episode twice when it is also resumable.
            let resumeIds = Set(resumeItems.value?.map(\.id) ?? [])
            let filtered = items.filter { !resumeIds.contains($0.id) }
            if !filtered.isEmpty { fresh.append(HomeSection(kind: .nextUp, title: L10n.nextUp, items: filtered)) }
        }
        for (library, items) in latest where !items.isEmpty {
            fresh.append(HomeSection(kind: .latest(libraryId: library.id), title: L10n.recentlyAddedIn(library.displayTitle), items: items))
        }
        if libraries.videoLibraries.count > 1 || fresh.isEmpty {
            fresh.append(HomeSection(kind: .libraries, title: L10n.libraries, items: libraries.videoLibraries))
        }
        if !collectionItems.isEmpty {
            fresh.append(HomeSection(kind: .collections, title: L10n.collections, items: collectionItems))
        }

        let failures = [resumeItems.error, nextUpItems.error].compactMap { $0 }
        if fresh.isEmpty, let failure = failures.first {
            error = failure
        } else {
            error = nil
            sections = fresh
            lastLoaded = Date()
            HomeSnapshot.save(fresh, accountId: session.account.id)
        }
    }

    /// Removes an item locally (e.g. after "mark as watched") until the next refresh.
    func remove(itemId: String, from kind: HomeSection.Kind) {
        guard let index = sections.firstIndex(where: { $0.kind == kind }) else { return }
        sections[index].items.removeAll { $0.id == itemId }
        if sections[index].items.isEmpty { sections.remove(at: index) }
    }

    private struct FetchResult<T> {
        var value: T?
        var error: (any Error)?
    }

    private func fetch<T>(_ operation: @escaping () async throws -> T) async -> FetchResult<T> {
        do {
            return FetchResult(value: try await operation(), error: nil)
        } catch {
            Log.warning(.jellyfin, "Home section failed: \(VelaError.wrap(error))")
            return FetchResult(value: nil, error: error)
        }
    }
}

/// Tiny cache of the last Home sections. Jellyfin stays the source of truth; this only
/// bridges the first second after launch.
enum HomeSnapshot {
    private static func url(_ accountId: String) -> URL {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("Home", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let safe = accountId.replacingOccurrences(of: "|", with: "_")
        return dir.appendingPathComponent("\(safe).json")
    }

    private struct Stored: Codable {
        struct Section: Codable {
            var kindKey: String
            var title: String
            var items: [BaseItem]
        }
        var sections: [Section]
    }

    static func save(_ sections: [HomeSection], accountId: String) {
        let stored = Stored(sections: sections.map { .init(kindKey: key($0.kind), title: $0.title, items: Array($0.items.prefix(20))) })
        if let data = try? JSONEncoder().encode(stored) {
            try? data.write(to: url(accountId), options: .atomic)
        }
    }

    static func load(accountId: String) -> [HomeSection]? {
        guard let data = try? Data(contentsOf: url(accountId)), let stored = try? JSONDecoder().decode(Stored.self, from: data) else { return nil }
        return stored.sections.compactMap { section in
            guard let kind = kind(from: section.kindKey) else { return nil }
            return HomeSection(kind: kind, title: section.title, items: section.items)
        }
    }

    static func clear() {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("Home", isDirectory: true)
        try? FileManager.default.removeItem(at: dir)
    }

    private static func key(_ kind: HomeSection.Kind) -> String {
        switch kind {
        case .continueWatching: "continue"
        case .nextUp: "nextup"
        case .latest(let id): "latest:\(id)"
        case .libraries: "libraries"
        case .collections: "collections"
        }
    }

    private static func kind(from key: String) -> HomeSection.Kind? {
        if key == "continue" { return .continueWatching }
        if key == "nextup" { return .nextUp }
        if key == "libraries" { return .libraries }
        if key == "collections" { return .collections }
        if key.hasPrefix("latest:") { return .latest(libraryId: String(key.dropFirst(7))) }
        return nil
    }
}
