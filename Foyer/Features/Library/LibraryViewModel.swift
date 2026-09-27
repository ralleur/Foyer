import Foundation
import Observation
import FoyerFoundation
import JellyfinKit

enum LibrarySort: String, CaseIterable, Identifiable {
    case name, dateAdded, year, rating

    var id: String { rawValue }

    var title: String {
        switch self {
        case .name: L10n.sortName
        case .dateAdded: L10n.sortDateAdded
        case .year: L10n.sortYear
        case .rating: L10n.sortRating
        }
    }

    var sortBy: [ItemSortBy] {
        switch self {
        case .name: [.sortName]
        case .dateAdded: [.dateCreated, .sortName]
        case .year: [.productionYear, .premiereDate, .sortName]
        case .rating: [.communityRating, .sortName]
        }
    }

    var order: JellyfinKit.SortOrder {
        switch self {
        case .name: .ascending
        default: .descending
        }
    }
}

enum LibraryFilter: String, CaseIterable, Identifiable {
    case all, unwatched, favorites

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: L10n.filterAll
        case .unwatched: L10n.filterUnwatched
        case .favorites: L10n.filterFavorites
        }
    }
}

/// Paged grid data source. Pages of 100 keep memory flat even for 20 000 items:
/// only the loaded pages live in memory and the grid is lazy.
@MainActor
@Observable
final class LibraryViewModel {
    let container: BaseItem
    private(set) var items: [BaseItem] = []
    private(set) var totalCount: Int?
    private(set) var isLoading = false
    private(set) var error: (any Error)?
    var sort: LibrarySort = .name { didSet { if oldValue != sort { Task { await reload() } } } }
    var filter: LibraryFilter = .all { didSet { if oldValue != filter { Task { await reload() } } } }

    private let pageSize = 100
    private var client: JellyfinClient?
    private var loadedAll = false
    private var generation = 0

    init(container: BaseItem) {
        self.container = container
        if container.collectionType == .movies || container.collectionType == .tvshows { sort = .name }
    }

    var isEmpty: Bool { items.isEmpty && !isLoading && error == nil && totalCount == 0 }

    func start(client: JellyfinClient) async {
        guard self.client == nil else { return }
        self.client = client
        await reload()
    }

    func reload() async {
        generation += 1
        let current = generation
        items = []
        totalCount = nil
        loadedAll = false
        error = nil
        await loadPage(generation: current)
    }

    func loadMoreIfNeeded(currentIndex: Int) {
        guard !isLoading, !loadedAll, currentIndex >= items.count - 30 else { return }
        let current = generation
        Task { await loadPage(generation: current) }
    }

    private func loadPage(generation current: Int) async {
        guard let client, !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        var query = ItemsQuery(parentId: container.id, sortBy: sort.sortBy, sortOrder: sort.order, startIndex: items.count, limit: pageSize)
        query.fields = ItemField.card
        switch container.collectionType {
        case .movies?:
            query.includeItemTypes = [.movie]
            query.recursive = true
        case .tvshows?:
            query.includeItemTypes = [.series]
            query.recursive = true
        case .boxsets?:
            query.includeItemTypes = [.boxSet]
            query.recursive = true
        default:
            // Mixed folders, collections and home videos: browse the actual hierarchy.
            query.recursive = false
            query.includeItemTypes = []
        }
        if container.type == .boxSet {
            query.recursive = false
            query.includeItemTypes = []
        }
        switch filter {
        case .all: break
        case .unwatched: query.filters = [.isUnplayed]
        case .favorites: query.filters = [.isFavorite]
        }
        do {
            let result = try await client.items(query)
            guard current == generation else { return }
            items.append(contentsOf: result.items)
            totalCount = result.totalRecordCount ?? items.count
            if result.items.count < pageSize || items.count >= (result.totalRecordCount ?? Int.max) {
                loadedAll = true
            }
        } catch {
            guard current == generation else { return }
            self.error = error
            Log.error(.jellyfin, "Library page failed: \(FoyerError.wrap(error))")
        }
    }

    func update(_ item: BaseItem) {
        if let index = items.firstIndex(where: { $0.id == item.id }) {
            items[index] = item
        }
    }
}
