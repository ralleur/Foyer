import SwiftUI
import Observation
import FoyerFoundation
import JellyfinKit

@MainActor
@Observable
final class SearchViewModel {
    var query = ""
    private(set) var movies: [BaseItem] = []
    private(set) var shows: [BaseItem] = []
    private(set) var episodes: [BaseItem] = []
    private(set) var isSearching = false
    private(set) var error: (any Error)?
    private(set) var searchedTerm = ""

    var hasResults: Bool { !(movies.isEmpty && shows.isEmpty && episodes.isEmpty) }

    func search(client: JellyfinClient) async {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard term.count >= 2 else {
            movies = []; shows = []; episodes = []; searchedTerm = ""
            return
        }
        // Debounce typing / dictation.
        try? await Task.sleep(for: .milliseconds(350))
        guard !Task.isCancelled else { return }
        isSearching = true
        defer { isSearching = false }
        do {
            let results = try await client.search(term: term, limit: 60)
            guard !Task.isCancelled else { return }
            movies = results.filter { $0.isMovie }
            shows = results.filter { $0.isSeries }
            episodes = results.filter { $0.isEpisode }
            searchedTerm = term
            error = nil
        } catch {
            guard !Task.isCancelled else { return }
            self.error = error
        }
    }
}

struct SearchView: View {
    @Environment(AppEnvironment.self) private var environment
    @State private var model = SearchViewModel()
    @State private var path = NavigationPath()

    var body: some View {
        NavigationStack(path: $path) {
            ZStack {
                Color.foyerBackground.ignoresSafeArea()
                content
            }
            .searchable(text: $model.query, prompt: L10n.searchPrompt)
            .itemDestinations()
        }
        .task(id: model.query) {
            guard let client = environment.client else { return }
            await model.search(client: client)
        }
    }

    @ViewBuilder private var content: some View {
        let images = environment.client.map(ItemImages.init)
        if model.hasResults {
            ScrollView(.vertical) {
                LazyVStack(alignment: .leading, spacing: Spacing.rowGap) {
                    if !model.movies.isEmpty {
                        MediaRow(title: L10n.movies, items: model.movies) { item in
                            PosterCard(item: item, imageURL: images?.poster(item, width: 480), showProgress: false) { path.append(item) }
                        }
                    }
                    if !model.shows.isEmpty {
                        MediaRow(title: L10n.shows, items: model.shows) { item in
                            PosterCard(item: item, imageURL: images?.poster(item, width: 480), showProgress: false) { path.append(item) }
                        }
                    }
                    if !model.episodes.isEmpty {
                        MediaRow(title: L10n.episodes, items: model.episodes) { item in
                            LandscapeCard(item: item, imageURL: images?.landscape(item, width: 800)) { path.append(item) }
                        }
                    }
                }
                .padding(.vertical, Spacing.l)
            }
            .scrollClipDisabled()
            .accessibilityIdentifier("searchResults")
        } else if model.isSearching {
            LoadingView()
        } else if let error = model.error {
            ErrorStateView(error: error)
        } else if !model.searchedTerm.isEmpty {
            EmptyStateView(systemImage: "magnifyingglass", text: L10n.searchNoResults)
        } else {
            EmptyStateView(systemImage: "magnifyingglass", text: L10n.searchHint)
        }
    }
}
