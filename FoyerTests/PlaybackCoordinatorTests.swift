import XCTest
import UIKit
@testable import Foyer
import FoyerFoundation
import JellyfinKit
import PlaybackDecision

/// Records what the coordinator asks an engine to do.
@MainActor
final class MockEngine: PlaybackEngine {
    let kind: PlaybackEngineKind
    weak var delegate: (any PlaybackEngineDelegate)?
    var state: PlaybackEngineState = .idle
    var currentTime: TimeInterval = 0
    var duration: TimeInterval = 100
    var isPlaying: Bool { state == .playing }
    var statistics = PlaybackStatistics()
    var subtitleDelay: TimeInterval = 0
    var audioDelay: TimeInterval = 0
    let viewController = UIViewController()
    var loadRequests: [EngineLoadRequest] = []
    var seeks: [TimeInterval] = []
    var audioSelections: [Int] = []
    var subtitleSelections: [Int?] = []
    var canSwitchAudioInPlace = true
    var stopped = false

    init(kind: PlaybackEngineKind) { self.kind = kind }

    func load(_ request: EngineLoadRequest) { loadRequests.append(request); state = .loading }
    func play() { state = .playing; delegate?.engine(self, didChangeState: .playing) }
    func pause() { state = .paused; delegate?.engine(self, didChangeState: .paused) }
    func seek(to time: TimeInterval) { seeks.append(time); currentTime = time }
    func stop() { stopped = true }
    func selectAudio(streamIndex: Int) -> Bool { audioSelections.append(streamIndex); return canSwitchAudioInPlace }
    func selectSubtitle(streamIndex: Int?) -> Bool { subtitleSelections.append(streamIndex); return true }
    func updateSkipAction(title: String?) {}
    func updateNextEpisode(_ item: BaseItem?, artworkURL: URL?, creditsStart: TimeInterval?, autoplay: Bool) {}
    func updateTrackMenus(audio: [PlayerTrack], subtitles: [PlayerTrack], selectedAudio: Int?, selectedSubtitle: Int?) {}
    func appDidEnterBackground() {}
    func appWillEnterForeground() {}

    func simulateReady() {
        state = .playing
        delegate?.engine(self, didChangeState: .playing)
        delegate?.engine(self, didUpdateTime: currentTime, duration: duration)
    }
}

@MainActor
final class PlaybackCoordinatorTests: XCTestCase {
    private var client: JellyfinClient!
    private var preferences: Preferences!
    private var engines: [MockEngine] = []

    override func setUp() async throws {
        client = JellyfinClient(baseURL: URL(string: "https://uitest.local")!, identity: DeviceIdentity(deviceId: "test"),
                                transport: FixtureTransport(), accessToken: "t", userId: "user1")
        let suite = "PlaybackCoordinatorTests.\(UUID().uuidString)"
        preferences = Preferences(defaults: UserDefaults(suiteName: suite)!)
        engines = []
    }

    private func makeCoordinator(item: BaseItem, start: PlaybackStart = .automatic, capabilities: DeviceCapabilities = .appleTV4KHDR) -> PlaybackCoordinator {
        let coordinator = PlaybackCoordinator(item: item, mediaSourceId: nil, start: start, client: client, preferences: preferences,
                                              capabilities: capabilities, images: ImagePipeline())
        coordinator.engineFactory = { [weak self] kind in
            let engine = MockEngine(kind: kind)
            self?.engines.append(engine)
            return engine
        }
        return coordinator
    }

    private func waitUntilReady(_ coordinator: PlaybackCoordinator) async throws {
        for _ in 0..<200 {
            if coordinator.phase != .preparing { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("coordinator did not leave preparing: \(coordinator.phase)")
    }

    func testPreparesDirectPlayWithResumePositionAndTracks() async throws {
        // The fixture movie is an MKV with HDR10/DV, TrueHD + E-AC-3 (German) + DTS-HD and German forced SRT.
        let coordinator = makeCoordinator(item: BaseItem(id: "a1b2c3", name: "Dune", type: .movie))
        coordinator.begin()
        try await waitUntilReady(coordinator)
        XCTAssertEqual(coordinator.phase, .ready)
        let engine = try XCTUnwrap(engines.first)
        let request = try XCTUnwrap(engine.loadRequests.first)
        // German audio (index 2) is preferred; German forced subtitles (index 4) are kept.
        XCTAssertEqual(coordinator.selectedAudioIndex, 2)
        XCTAssertEqual(coordinator.selectedSubtitleIndex, 4)
        XCTAssertEqual(request.startPosition, 1200, accuracy: 0.5, "resume position from user data")
        // HDR MKV with E-AC-3 selected: system player after a server remux would be chosen, but the fixture server
        // grants direct play without a transcoding URL, so the decision is reconciled to direct play.
        XCTAssertNotNil(coordinator.decision)
        XCTAssertEqual(coordinator.audioTracks.count, 3)
        XCTAssertEqual(coordinator.subtitleTracks.count, 5, "off + 4 subtitle streams")
        XCTAssertTrue(request.url.absoluteString.contains("api_key="))
    }

    func testPlayFromBeginningIgnoresResume() async throws {
        let coordinator = makeCoordinator(item: BaseItem(id: "a1b2c3", name: "Dune", type: .movie), start: .beginning)
        coordinator.begin()
        try await waitUntilReady(coordinator)
        XCTAssertEqual(engines.first?.loadRequests.first?.startPosition, 0)
    }

    func testAudioSwitchInPlaceDoesNotReload() async throws {
        let coordinator = makeCoordinator(item: BaseItem(id: "a1b2c3", name: "Dune", type: .movie))
        coordinator.begin()
        try await waitUntilReady(coordinator)
        let engine = try XCTUnwrap(engines.first)
        engine.simulateReady()
        let english = try XCTUnwrap(coordinator.audioTracks.first { $0.streamIndex == 1 })
        coordinator.selectAudio(english)
        XCTAssertEqual(coordinator.selectedAudioIndex, 1)
        XCTAssertEqual(engine.audioSelections, [1])
        XCTAssertEqual(engines.count, 1, "no reload for an in-place switch")
    }

    func testAudioSwitchThatNeedsReloadCreatesNewEngineAtCurrentPosition() async throws {
        let coordinator = makeCoordinator(item: BaseItem(id: "a1b2c3", name: "Dune", type: .movie))
        coordinator.begin()
        try await waitUntilReady(coordinator)
        let engine = try XCTUnwrap(engines.first)
        engine.canSwitchAudioInPlace = false
        engine.currentTime = 1500
        engine.simulateReady()
        engine.delegate?.engine(engine, didUpdateTime: 1500, duration: 9984)
        let dts = try XCTUnwrap(coordinator.audioTracks.first { $0.streamIndex == 3 })
        coordinator.selectAudio(dts)
        for _ in 0..<200 where engines.count < 2 { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(engines.count, 2)
        XCTAssertEqual(engines.last?.loadRequests.first?.startPosition ?? -1, 1500, accuracy: 0.5)
        XCTAssertEqual(coordinator.selectedAudioIndex, 3)
    }

    func testEngineFailureFallsBackToAnotherRoute() async throws {
        let coordinator = makeCoordinator(item: BaseItem(id: "a1b2c3", name: "Dune", type: .movie))
        coordinator.begin()
        try await waitUntilReady(coordinator)
        let first = try XCTUnwrap(engines.first)
        let firstRoute = coordinator.decision?.route
        first.delegate?.engine(first, didFail: FoyerError(.formatUnsupported, detail: "test"))
        for _ in 0..<200 where engines.count < 2 { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(engines.count, 2, "a fallback route should have been attempted")
        XCTAssertNotEqual(coordinator.decision?.route, firstRoute)
        XCTAssertTrue(first.stopped)
    }

    func testCloseStopsEngineAndCallsBack() async throws {
        let coordinator = makeCoordinator(item: BaseItem(id: "a1b2c3", name: "Dune", type: .movie))
        let closed = expectation(description: "closed")
        coordinator.onClose = { closed.fulfill() }
        coordinator.begin()
        try await waitUntilReady(coordinator)
        let engine = try XCTUnwrap(engines.first)
        coordinator.close()
        XCTAssertTrue(engine.stopped)
        XCTAssertEqual(coordinator.phase, .finished)
        await fulfillment(of: [closed], timeout: 1)
    }
}
