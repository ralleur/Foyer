import Foundation

/// Query parameters for `/Items` and friends. Only what the app uses.
public struct ItemsQuery: Sendable, Hashable {
    public var parentId: String?
    public var ids: [String] = []
    public var includeItemTypes: [BaseItemKind] = []
    public var excludeItemTypes: [BaseItemKind] = []
    public var recursive: Bool = true
    public var sortBy: [ItemSortBy] = [.sortName]
    public var sortOrder: SortOrder = .ascending
    public var startIndex: Int = 0
    public var limit: Int? = 60
    public var fields: [ItemField] = ItemField.card
    public var filters: [ItemFilter] = []
    public var genres: [String] = []
    public var searchTerm: String?
    public var isPlayed: Bool?
    public var isFavorite: Bool?
    public var nameStartsWith: String?
    public var years: [Int] = []
    public var enableTotalRecordCount: Bool = true
    public var enableImageTypes: [ImageType] = [.primary, .backdrop, .thumb, .logo]
    public var imageTypeLimit: Int = 1
    public var collapseBoxSetItems: Bool?
    public var minCommunityRating: Double?
    public var hasOfficialRating: Bool?

    public init(parentId: String? = nil, includeItemTypes: [BaseItemKind] = [], sortBy: [ItemSortBy] = [.sortName],
                sortOrder: SortOrder = .ascending, startIndex: Int = 0, limit: Int? = 60) {
        self.parentId = parentId
        self.includeItemTypes = includeItemTypes
        self.sortBy = sortBy
        self.sortOrder = sortOrder
        self.startIndex = startIndex
        self.limit = limit
    }

    public var queryItems: [URLQueryItem] {
        var items: [URLQueryItem] = []
        func add(_ name: String, _ value: String?) {
            guard let value, !value.isEmpty else { return }
            items.append(URLQueryItem(name: name, value: value))
        }
        add("ParentId", parentId)
        add("Ids", ids.isEmpty ? nil : ids.joined(separator: ","))
        add("IncludeItemTypes", includeItemTypes.isEmpty ? nil : includeItemTypes.map(\.rawValue).joined(separator: ","))
        add("ExcludeItemTypes", excludeItemTypes.isEmpty ? nil : excludeItemTypes.map(\.rawValue).joined(separator: ","))
        add("Recursive", recursive ? "true" : "false")
        add("SortBy", sortBy.isEmpty ? nil : sortBy.map(\.rawValue).joined(separator: ","))
        add("SortOrder", sortOrder.rawValue)
        add("StartIndex", String(startIndex))
        add("Limit", limit.map(String.init))
        add("Fields", fields.isEmpty ? nil : fields.map(\.rawValue).joined(separator: ","))
        add("Filters", filters.isEmpty ? nil : filters.map(\.rawValue).joined(separator: ","))
        add("Genres", genres.isEmpty ? nil : genres.joined(separator: "|"))
        add("SearchTerm", searchTerm)
        add("IsPlayed", isPlayed.map { $0 ? "true" : "false" })
        add("IsFavorite", isFavorite.map { $0 ? "true" : "false" })
        add("NameStartsWith", nameStartsWith)
        add("Years", years.isEmpty ? nil : years.map(String.init).joined(separator: ","))
        add("EnableTotalRecordCount", enableTotalRecordCount ? "true" : "false")
        add("EnableImageTypes", enableImageTypes.isEmpty ? nil : enableImageTypes.map(\.rawValue).joined(separator: ","))
        add("ImageTypeLimit", String(imageTypeLimit))
        add("CollapseBoxSetItems", collapseBoxSetItems.map { $0 ? "true" : "false" })
        add("MinCommunityRating", minCommunityRating.map { String($0) })
        add("HasOfficialRating", hasOfficialRating.map { $0 ? "true" : "false" })
        return items
    }
}
