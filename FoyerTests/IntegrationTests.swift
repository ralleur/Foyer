import XCTest
@testable import Foyer
import FoyerFoundation
import JellyfinKit
import PlaybackDecision

/// End-to-end flows against the canned server (FixtureTransport): sign in, load libraries,
/// load Home, and verify the playback session reports the server expects.
@MainActor
final class SessionFlowTests: XCTestCase {
    private var transport: FixtureTransport!
    private var store: SessionStore!
    private var suite: String!

    override func setUp() async throws {
        transport = FixtureTransport()
        suite = "SessionFlowTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let transport = self.transport!
        store = SessionStore(transportFactory: { transport }, keychain: InMemoryKeychain(), defaults: defaults)
    }

    override func tearDown() {
        UserDefaults().removePersistentDomain(forName: suite)
    }

    func testDiscoverAndSignInStoresAccountAndToken() async throws {
        let server = try await store.discover("uitest.local")
        XCTAssertEqual(server.name, "Heimserver")
        XCTAssertEqual(server.version, "10.10.3")
        XCTAssertTrue(server.isSecure, "https is probed first")

        let users = await store.publicUsers(for: server)
        XCTAssertEqual(users.map(\.name), ["anna", "kids"])
        let quick = await store.quickConnectAvailable(for: server)
        XCTAssertTrue(quick)

        try await store.signIn(server: server, username: "anna", password: "secret")
        let active = try XCTUnwrap(store.active)
        XCTAssertEqual(active.account.userName, "anna")
        XCTAssertEqual(active.client.accessToken, "tok_ABC")
        XCTAssertTrue(active.client.isAuthenticated)
        XCTAssertEqual(store.accounts.count, 1)
        XCTAssertTrue(transport.log.contains("POST /Users/AuthenticateByName"))

        // Switching away and back restores the token from the keychain.
        store.detachActiveForOnboarding()
        XCTAssertNil(store.active)
        store.activate(active.account)
        XCTAssertEqual(store.active?.client.accessToken, "tok_ABC")

        await store.signOut(active.account)
        XCTAssertNil(store.active)
        XCTAssertTrue(store.accounts.isEmpty)
        XCTAssertTrue(transport.log.contains("POST /Sessions/Logout"))
    }

    func testInvalidAddressIsRejectedBeforeNetwork() async {
        do {
            _ = try await store.discover("ftp://nope")
            XCTFail("expected failure")
        } catch let error as FoyerError {
            XCTAssertEqual(error.kind, .invalidServerAddress)
        } catch {
            XCTFail("unexpected \(error)")
        }
        XCTAssertTrue(transport.log.isEmpty)
    }

    func testLibrariesAndHomeLoad() async throws {
        store.installUITestSession()
        let session = try XCTUnwrap(store.active)
        let libraries = LibrariesModel()
        await libraries.load(client: session.client)
        XCTAssertEqual(libraries.videoLibraries.map(\.name), ["Filme", "Serien"], "music library is hidden")
        XCTAssertEqual(libraries.movieLibraries.count, 1)
        XCTAssertEqual(libraries.showLibraries.count, 1)

        let home = HomeViewModel()
        await home.load(session: session, libraries: libraries)
        let kinds = home.sections.map(\.kind)
        XCTAssertTrue(kinds.contains(.continueWatching))
        XCTAssertTrue(kinds.contains(.nextUp))
        XCTAssertTrue(kinds.contains(.latest(libraryId: "lib-movies")))
        XCTAssertTrue(kinds.contains(.libraries))
        let resume = try XCTUnwrap(home.sections.first { $0.kind == .continueWatching })
        XCTAssertEqual(resume.items.map(\.id), ["ep1", "mv1"])
        // Snapshot is written and can be restored instantly on next launch.
        XCTAssertNotNil(HomeSnapshot.load(accountId: session.account.id))
    }

    func testLibraryPagingAndSeriesModels() async throws {
        store.installUITestSession()
        let client = try XCTUnwrap(store.active?.client)
        let library = BaseItem(id: "lib-shows", name: "Serien", type: .collectionFolder)
        var shows = library
        shows.collectionType = .tvshows
        let model = LibraryViewModel(container: shows)
        await model.start(client: client)
        XCTAssertEqual(model.items.map(\.name), ["The Expanse", "Severance"])
        XCTAssertEqual(model.totalCount, 2)

        let series = SeriesViewModel(seriesId: "series1", initialSeries: nil, initialSeasonId: nil)
        await series.load(client: client)
        XCTAssertEqual(series.series?.name, "The Expanse")
        XCTAssertEqual(series.seasons.count, 2)
        XCTAssertEqual(series.nextUp?.id, "ep3")
        XCTAssertEqual(series.selectedSeasonId, "season1")
        for _ in 0..<50 where series.selectedEpisodes.isEmpty { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(series.selectedEpisodes.count, 3)
        XCTAssertEqual(series.primaryEpisode?.id, "ep3")
        XCTAssertTrue(series.primaryActionTitle?.contains("S1 · E3") == true)
    }
}

@MainActor
final class PlaybackReportingTests: XCTestCase {
    func testStartProgressAndStopAreReported() async throws {
        let transport = FixtureTransport()
        let client = JellyfinClient(baseURL: URL(string: "https://uitest.local")!, identity: DeviceIdentity(deviceId: "test"),
                                    transport: transport, accessToken: "t", userId: "user1")
        let preferences = Preferences(defaults: UserDefaults(suiteName: "PlaybackReportingTests.\(UUID().uuidString)")!)
        let coordinator = PlaybackCoordinator(item: BaseItem(id: "a1b2c3", name: "Dune", type: .movie), mediaSourceId: nil, start: .beginning,
                                              client: client, preferences: preferences, capabilities: .appleTV4KHDR, images: ImagePipeline())
        var engines: [MockEngine] = []
        coordinator.engineFactory = { kind in
            let engine = MockEngine(kind: kind)
            engines.append(engine)
            return engine
        }
        coordinator.begin()
        for _ in 0..<200 where coordinator.phase == .preparing { try await Task.sleep(for: .milliseconds(20)) }
        let engine = try XCTUnwrap(engines.first)
        XCTAssertTrue(transport.log.contains { $0.hasSuffix("/Items/a1b2c3/PlaybackInfo") })

        engine.simulateReady()
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(transport.log.contains("POST /Sessions/Playing"), "start report after first frame")

        engine.currentTime = 30
        engine.pause()
        try await Task.sleep(for: .milliseconds(1200))
        engine.play()
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(transport.log.contains("POST /Sessions/Playing/Progress"), "pause/resume reports progress")

        coordinator.close()
        for _ in 0..<50 where !transport.log.contains("POST /Sessions/Playing/Stopped") { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(transport.log.contains("POST /Sessions/Playing/Stopped"))
    }
}
