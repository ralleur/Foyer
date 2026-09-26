import SwiftUI
import FoyerFoundation
import JellyfinKit

struct HomeView: View {
    let libraries: LibrariesModel
    @Environment(AppEnvironment.self) private var environment
    @State private var model = HomeViewModel()
    @State private var path = NavigationPath()
    @State private var focusedBackdrop: URL?

    var body: some View {
        NavigationStack(path: $path) {
            ZStack {
                HeroBackdrop(url: focusedBackdrop, opacity: 0.32)
                    .animation(Motion.content, value: focusedBackdrop)
                content
            }
            .itemDestinations()
        }
        .task(id: environment.sessionStore.active?.account.id) {
            guard let session = environment.sessionStore.active else { return }
            await model.loadIfNeeded(session: session, libraries: libraries)
        }
        .onChange(of: environment.playback == nil) { _, playerClosed in
            // Returning from the player: refresh Continue Watching.
            if playerClosed, let session = environment.sessionStore.active {
                Task { await model.loadIfNeeded(session: session, libraries: libraries, force: true) }
            }
        }
    }

    @ViewBuilder private var content: some View {
        if model.sections.isEmpty {
            if model.isLoading {
                LoadingView()
            } else if let error = model.error {
                ErrorStateView(error: error) {
                    Task {
                        if let session = environment.sessionStore.active {
                            await model.load(session: session, libraries: libraries)
                        }
                    }
                }
            } else {
                EmptyStateView(systemImage: "film.stack", text: L10n.homeEmpty)
            }
        } else {
            ScrollView(.vertical) {
                LazyVStack(alignment: .leading, spacing: Spacing.rowGap) {
                    ForEach(model.sections) { section in
                        sectionView(section)
                    }
                }
                .padding(.top, Spacing.l)
                .padding(.bottom, Spacing.xl)
            }
            .scrollClipDisabled()
            .accessibilityIdentifier("homeScroll")
        }
    }

    @ViewBuilder private func sectionView(_ section: HomeSection) -> some View {
        let images = environment.client.map(ItemImages.init)
        switch section.kind {
        case .continueWatching, .nextUp:
            MediaRow(title: section.title, items: section.items) { item in
                LandscapeCard(item: item,
                              imageURL: images?.landscape(item, width: 800),
                              size: CardSize.landscapeLarge,
                              onFocus: { focusedBackdrop = images?.backdrop($0) }) {
                    environment.play(item, start: .automatic)
                }
                .contextMenu { itemContextMenu(item, section: section.kind) }
            }
        case .latest, .collections:
            MediaRow(title: section.title, items: section.items) { item in
                PosterCard(item: item,
                           imageURL: images?.poster(item, width: 480),
                           showProgress: false,
                           onFocus: { focusedBackdrop = images?.backdrop($0) }) {
                    path.append(item)
                }
                .contextMenu { itemContextMenu(item, section: section.kind) }
            }
        case .libraries:
            MediaRow(title: section.title, items: section.items) { library in
                LibraryTile(title: library.displayTitle,
                            imageURL: images?.poster(library, width: 800),
                            systemImage: library.collectionType == .tvshows ? "tv" : "film") {
                    path.append(library)
                }
            }
        }
    }

    @ViewBuilder private func itemContextMenu(_ item: BaseItem, section: HomeSection.Kind) -> some View {
        Button {
            path.append(item)
        } label: {
            Label(L10n.details, systemImage: "info.circle")
        }
        if item.isPlayable {
            Button {
                environment.play(item, start: .beginning)
            } label: {
                Label(L10n.playFromBeginning, systemImage: "gobackward")
            }
            Button {
                Task {
                    await environment.setPlayed(item, played: !item.isPlayed)
                    model.remove(itemId: item.id, from: section)
                }
            } label: {
                Label(item.isPlayed ? L10n.markUnwatched : L10n.markWatched, systemImage: item.isPlayed ? "eye.slash" : "eye")
            }
        }
    }
}
