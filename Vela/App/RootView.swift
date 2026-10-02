import SwiftUI
import VelaFoundation

struct RootView: View {
    @Environment(AppEnvironment.self) private var environment

    var body: some View {
        Group {
            #if DEBUG
            if let url = environment.debugPlayURL {
                DebugURLPlayerScreen(url: url).ignoresSafeArea()
            } else if let session = environment.sessionStore.active {
                MainTabView(session: session)
                    .id(session.account.id)
            } else {
                OnboardingFlow()
            }
            #else
            if let session = environment.sessionStore.active {
                MainTabView(session: session)
                    .id(session.account.id)
            } else {
                OnboardingFlow()
            }
            #endif
        }
        .background(Color.velaBackground.ignoresSafeArea())
        .onOpenURL { environment.open($0) }
        .remoteMessageBanner()
        .animation(.easeInOut(duration: 0.25), value: environment.sessionStore.active?.account.id)
    }
}

/// Top-level navigation. Tabs are derived from the user's video libraries.
struct MainTabView: View {
    let session: ActiveSession
    @Environment(AppEnvironment.self) private var environment
    @State private var libraries = LibrariesModel()
    @State private var selection: MainTab = .home

    enum MainTab: Hashable {
        case home
        case library(String)
        case search
        case settings
    }

    var body: some View {
        TabView(selection: $selection) {
            HomeView(libraries: libraries)
                .tabItem { Label(L10n.home, systemImage: "house") }
                .tag(MainTab.home)

            ForEach(libraries.videoLibraries) { library in
                LibraryView(library: library)
                    .tabItem { Text(library.displayTitle) }
                    .tag(MainTab.library(library.id))
            }

            SearchView()
                .tabItem { Label(L10n.search, systemImage: "magnifyingglass") }
                .tag(MainTab.search)

            SettingsView()
                .tabItem { Label(L10n.settings, systemImage: "gearshape") }
                .tag(MainTab.settings)
        }
        .onChange(of: environment.pendingDetail?.id) { _, id in
            // Deep links open their detail screen on the Home tab.
            if id != nil { selection = .home }
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
