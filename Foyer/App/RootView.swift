import SwiftUI
import FoyerFoundation

struct RootView: View {
    @Environment(AppEnvironment.self) private var environment

    var body: some View {
        Group {
            if let session = environment.sessionStore.active {
                MainTabView(session: session)
                    .id(session.account.id)
            } else {
                OnboardingFlow()
            }
        }
        .background(Color.foyerBackground.ignoresSafeArea())
        .animation(.easeInOut(duration: 0.25), value: environment.sessionStore.active?.account.id)
    }
}

/// Top-level navigation. Tabs are derived from the user's video libraries.
struct MainTabView: View {
    let session: ActiveSession
    @Environment(AppEnvironment.self) private var environment
    @State private var libraries = LibrariesModel()

    var body: some View {
        TabView {
            HomeView(libraries: libraries)
                .tabItem { Label(L10n.home, systemImage: "house") }

            ForEach(libraries.videoLibraries) { library in
                LibraryView(library: library)
                    .tabItem { Text(library.displayTitle) }
            }

            SearchView()
                .tabItem { Label(L10n.search, systemImage: "magnifyingglass") }

            SettingsView()
                .tabItem { Label(L10n.settings, systemImage: "gearshape") }
        }
        .task(id: session.account.id) {
            await libraries.load(client: session.client)
        }
        .fullScreenCover(item: Binding(
            get: { environment.playback },
            set: { if $0 == nil { environment.playback = nil } }
        )) { coordinator in
            PlayerScreen(coordinator: coordinator)
                .ignoresSafeArea()
        }
    }
}
