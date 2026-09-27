import XCTest
import UIKit
@testable import Vela
import VelaFoundation
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
    func setControlsVisible(_ visible: Bool) {}
    var bitmapSubtitles: [BitmapSubtitleSource?] = []
    func setBitmapSubtitle(_ source: BitmapSubtitleSource?) { bitmapSubtitles.append(source) }
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
        first.delegate?.engine(first, didFail: VelaError(.formatUnsupported, detail: "test"))
        for _ in 0..<200 where engines.count < 2 { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(engines.count, 2, "a fallback route should have been attempted")
        XCTAssertNotEqual(coordinator.decision?.route, firstRoute)
        XCTAssertTrue(first.stopped)
    }

    func testCreditsCountdownOnAdvancedEngine() async throws {
        // Episode fixture: MKV, segments intro 0:30–2:00 and outro 41:40–45:00, next episode ep2 in the same season.
        preferences.playback.advancedEngineMode = .always
        var episode = BaseItem(id: "ep1", name: "Dulcinea", type: .episode)
        episode.seriesId = "series1"
        episode.seasonId = "season1"
        let coordinator = makeCoordinator(item: episode)
        coordinator.begin()
        try await waitUntilReady(coordinator)
        let engine = try XCTUnwrap(engines.first)
        XCTAssertEqual(engine.kind, .advanced)
        engine.duration = 2700
        engine.simulateReady()
        for _ in 0..<100 where coordinator.nextEpisode == nil { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(coordinator.nextEpisode?.id, "ep2")

        // Segments load asynchronously; the intro prompt shows up within the first seconds of the segment.
        for _ in 0..<100 where coordinator.skipPrompt == .none {
            engine.delegate?.engine(engine, didUpdateTime: 35, duration: 2700)
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(coordinator.skipPrompt, .skipIntro(to: 120))
        XCTAssertNil(coordinator.countdownSeconds)

        engine.delegate?.engine(engine, didUpdateTime: 2600, duration: 2700)
        XCTAssertEqual(coordinator.countdownSeconds, 10, "countdown starts in the credits")
        engine.delegate?.engine(engine, didUpdateTime: 2695, duration: 2700)
        XCTAssertEqual(coordinator.countdownSeconds, 5)

        coordinator.cancelCountdown()
        engine.delegate?.engine(engine, didUpdateTime: 2696, duration: 2700)
        XCTAssertNil(coordinator.countdownSeconds, "cancelled countdown stays cancelled")
        XCTAssertEqual(engines.count, 1, "no autoplay after cancel")
    }

    func testFallbackAfterFailedSeekResumesAtSeekTarget() async throws {
        let coordinator = makeCoordinator(item: BaseItem(id: "a1b2c3", name: "Dune", type: .movie))
        coordinator.begin()
        try await waitUntilReady(coordinator)
        let first = try XCTUnwrap(engines.first)
        first.simulateReady()
        first.delegate?.engine(first, didUpdateTime: 1210, duration: 9984)
        coordinator.seek(to: 3000)
        XCTAssertEqual(first.seeks, [3000])
        // AVPlayer keeps reporting the old position while the seek is in flight; it must not win.
        first.delegate?.engine(first, didUpdateTime: 1211, duration: 9984)
        XCTAssertEqual(coordinator.currentTime, 3000, accuracy: 0.5)
        first.delegate?.engine(first, didFail: VelaError(.videoLoadFailed, detail: "segment"))
        for _ in 0..<200 where engines.count < 2 { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(engines.count, 2)
        XCTAssertEqual(engines.last?.loadRequests.first?.startPosition ?? -1, 3000, accuracy: 0.5, "fallback resumes at the seek target")
        // After a completed seek, time updates flow again.
        let second = try XCTUnwrap(engines.last)
        second.simulateReady()
        second.currentTime = 3001
        second.delegate?.engineDidCompleteSeek(second)
        second.delegate?.engine(second, didUpdateTime: 3002, duration: 9984)
        XCTAssertEqual(coordinator.currentTime, 3002, accuracy: 0.5)
    }

    func testBitmapSubtitleOnHDRStaysNativeWithOverlay() async throws {
        // Dune fixture: HDR MKV with an English PGS track (index 6). Selecting it keeps the system player (HDR remux)
        // and hands the engine a bitmap source decoded from the original file instead of switching to mpv.
        let coordinator = makeCoordinator(item: BaseItem(id: "a1b2c3", name: "Dune", type: .movie))
        coordinator.preferredSubtitleStreamIndex = 6
        coordinator.begin()
        try await waitUntilReady(coordinator)
        let engine = try XCTUnwrap(engines.first)
        XCTAssertEqual(engine.kind, .native)
        XCTAssertEqual(coordinator.decision?.subtitleHandling, .bitmapOverlay)
        XCTAssertEqual(coordinator.selectedSubtitleIndex, 6)
        XCTAssertTrue(engine.bitmapSubtitles.compactMap { $0 }.isEmpty, "the overlay waits until the player runs (the remux gets the disk first)")
        engine.simulateReady()
        let source = try XCTUnwrap(engine.bitmapSubtitles.last ?? nil, "engine received a bitmap subtitle source once playing")
        XCTAssertEqual(source.streamIndex, 6)
        XCTAssertTrue(source.url.absoluteString.contains("static=true"), "decoded from the original file, not the remux")
        // Switching subtitles off stops the overlay without reloading.
        coordinator.selectSubtitle(.subtitlesOff)
        XCTAssertNil(coordinator.selectedSubtitleIndex)
        XCTAssertTrue(source.isStopped)
        XCTAssertEqual(engines.count, 1)
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
