import SwiftUI
import JellyfinKit

/// A library tab: paged poster grid with sort and filter.
struct LibraryView: View {
    let library: BaseItem
    @State private var path = NavigationPath()

    var body: some View {
        NavigationStack(path: $path) {
            LibraryGridView(container: library) { item in
                path.append(item)
            }
            .itemDestinations()
        }
    }
}

struct LibraryGridView: View {
    let container: BaseItem
    let onSelect: (BaseItem) -> Void
    @Environment(AppEnvironment.self) private var environment
    @State private var model: LibraryViewModel

    init(container: BaseItem, onSelect: @escaping (BaseItem) -> Void) {
        self.container = container
        self.onSelect = onSelect
        self._model = State(initialValue: LibraryViewModel(container: container))
    }

    private let columns = [GridItem(.adaptive(minimum: CardSize.poster.width, maximum: CardSize.poster.width), spacing: Spacing.l, alignment: .top)]

    var body: some View {
        ZStack {
            Color.foyerBackground.ignoresSafeArea()
            VStack(alignment: .leading, spacing: 0) {
                header
                if model.items.isEmpty {
                    if model.isLoading {
                        LoadingView()
                    } else if let error = model.error {
                        ErrorStateView(error: error) { Task { await model.reload() } }
                    } else {
                        EmptyStateView(systemImage: "square.grid.2x2", text: L10n.libraryEmpty)
                    }
                } else {
                    grid
                }
            }
        }
        .task(id: environment.client?.baseURL) {
            if let client = environment.client { await model.start(client: client) }
        }
        .onChange(of: environment.playback == nil) { _, closed in
            if closed { Task { await model.reload() } }
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.l) {
            Text(container.displayTitle)
                .font(Typography.screenTitle)
            if let total = model.totalCount {
                Text(L10n.itemCount(total))
                    .font(Typography.meta)
                    .foregroundStyle(Color.foyerTertiaryText)
            }
            Spacer()
            Picker(L10n.filterAll, selection: $model.filter) {
                ForEach(LibraryFilter.allCases) { filter in
                    Text(filter.title).tag(filter)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 560)
            .accessibilityLabel("Filter")
            Menu {
                Picker(L10n.sortBy, selection: $model.sort) {
                    ForEach(LibrarySort.allCases) { sort in
                        Text(sort.title).tag(sort)
                    }
                }
            } label: {
                Label(model.sort.title, systemImage: "arrow.up.arrow.down")
                    .font(Typography.meta)
            }
            .accessibilityIdentifier("sortMenu")
        }
        .padding(.horizontal, Spacing.screenEdge)
        .padding(.top, Spacing.m)
        .padding(.bottom, Spacing.m)
        .focusSection()
    }

    private var grid: some View {
        let images = environment.client.map(ItemImages.init)
        return ScrollView(.vertical) {
            LazyVGrid(columns: columns, alignment: .leading, spacing: Spacing.l) {
                ForEach(Array(model.items.enumerated()), id: \.element.id) { index, item in
                    PosterCard(item: item, imageURL: images?.poster(item, width: 480), showProgress: item.isPlayable) {
                        if item.isPlayable, container.type == .boxSet || container.collectionType == .homevideos {
                            environment.play(item, start: .automatic)
                        } else {
                            onSelect(item)
                        }
                    }
                    .contextMenu {
                        Button { onSelect(item) } label: { Label(L10n.details, systemImage: "info.circle") }
                        if item.isPlayable {
                            Button { environment.play(item, start: .automatic) } label: { Label(L10n.play, systemImage: "play.fill") }
                        }
                        Button {
                            Task {
                                if let updated = await environment.setPlayed(item, played: !item.isPlayed) { model.update(updated) }
                            }
                        } label: {
                            Label(item.isPlayed ? L10n.markUnwatched : L10n.markWatched, systemImage: item.isPlayed ? "eye.slash" : "eye")
                        }
                    }
                    .onAppear { model.loadMoreIfNeeded(currentIndex: index) }
                }
            }
            .padding(.horizontal, Spacing.screenEdge)
            .padding(.vertical, Spacing.l)
            .frame(maxWidth: .infinity, alignment: .leading)
            .focusSection()
            if model.isLoading {
                ProgressView().padding(Spacing.l)
            }
        }
        .scrollClipDisabled()
        .accessibilityIdentifier("libraryGrid")
    }
}

/// Collections (box sets) and folders: header with artwork and description, then the grid.
/// Pushed inside an existing NavigationStack, so it navigates via `navigationDestination(item:)`.
struct CollectionDetailView: View {
    let container: BaseItem
    @Environment(AppEnvironment.self) private var environment
    @State private var pushed: BaseItem?

    var body: some View {
        ZStack {
            if let images = environment.client.map(ItemImages.init) {
                HeroBackdrop(url: images.backdrop(container), opacity: 0.3)
            }
            VStack(alignment: .leading, spacing: 0) {
                if let overview = container.overview, !overview.isEmpty {
                    Text(overview)
                        .font(Typography.body)
                        .foregroundStyle(Color.foyerSecondaryText)
                        .lineLimit(3)
                        .frame(maxWidth: 1200, alignment: .leading)
                        .padding(.horizontal, Spacing.screenEdge)
                        .padding(.top, Spacing.m)
                }
                LibraryGridView(container: container) { item in
                    pushed = item
                }
            }
        }
        .navigationDestination(item: $pushed) { item in
            ItemDestination(item: item)
        }
    }
}
