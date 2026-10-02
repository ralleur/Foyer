import XCTest
@testable import Vela
import VelaFoundation
import JellyfinKit
import PlaybackDecision

@MainActor
final class RemoteControlTests: XCTestCase {
    /// Records what the service hands to the app.
    final class Recorder: RemoteCommandHandler {
        var plays: [RemotePlayRequest] = []
        var states: [(PlayStateCommand, TimeInterval?)] = []
        var generals: [GeneralCommand] = []
        func remotePlay(_ request: RemotePlayRequest) async { plays.append(request) }
        func remotePlayState(_ command: PlayStateCommand, seekPosition: TimeInterval?) { states.append((command, seekPosition)) }
        func remoteGeneral(_ command: GeneralCommand) { generals.append(command) }
    }

    func testDispatchesParsedFramesToHandler() async throws {
        let service = RemoteControlService()
        let recorder = Recorder()
        service.handler = recorder
        let play = try XCTUnwrap(SessionMessage.parse(Data(#"{"MessageType":"Play","Data":{"ItemIds":["A1-B2"],"PlayCommand":"PlayNow","StartPositionTicks":150000000}}"#.utf8)))
        service.dispatch(play)
        service.dispatch(.command(.playState(.seek, seekPositionTicks: 30_000_000)))
        service.dispatch(.command(.general(GeneralCommand(name: "DisplayMessage", arguments: ["Text": "Dinner"]))))
        service.dispatch(.other(type: "LibraryChanged"))
        for _ in 0..<100 where recorder.plays.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(recorder.plays.first?.firstItemId, "a1b2")
        XCTAssertEqual(recorder.plays.first?.startPosition, 15)
        XCTAssertEqual(recorder.states.first?.0, .seek)
        XCTAssertEqual(recorder.states.first?.1, 3)
        XCTAssertEqual(recorder.generals.first?.name, "DisplayMessage")
    }

    private func makeEnvironment() -> AppEnvironment {
        let suite = "RemoteControlTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let store = SessionStore(transportFactory: { FixtureTransport() }, keychain: InMemoryKeychain(), defaults: defaults)
        store.installUITestSession()
        return AppEnvironment(preferences: Preferences(defaults: defaults), sessionStore: store, images: ImagePipeline(),
                              logBuffer: LogBuffer(), capabilities: .appleTV4KHDR, isUITest: true)
    }

    func testRemotePlayOpensPlayerWithPositionAndTracks() async throws {
        let environment = makeEnvironment()
        XCTAssertFalse(environment.remoteControl.isConnected, "UI-test sessions never open a socket")
        await environment.remotePlay(RemotePlayRequest(itemIds: ["a1b2c3"], startPositionTicks: 150_000_000, audioStreamIndex: 1, subtitleStreamIndex: -1))
        let coordinator = try XCTUnwrap(environment.playback)
        XCTAssertEqual(coordinator.item.id, "a1b2c3")
        XCTAssertEqual(coordinator.preferredAudioStreamIndex, 1)
        XCTAssertEqual(coordinator.preferredSubtitleStreamIndex, -1)
        // Play-state commands reach the presented player; Stop dismisses it.
        environment.remotePlayState(.stop, seekPosition: nil)
        XCTAssertNil(environment.playback)
        // A queue is not something Vela has: PlayNext/PlayLast are declined, not faked.
        await environment.remotePlay(RemotePlayRequest(itemIds: ["a1b2c3"], mode: .playLast))
        XCTAssertNil(environment.playback)
    }

    func testDisplayMessageBecomesBanner() {
        let environment = makeEnvironment()
        environment.remoteGeneral(GeneralCommand(name: "DisplayMessage", arguments: ["Header": "Kitchen", "Text": "Dinner is ready", "TimeoutMs": "4000"]))
        XCTAssertEqual(environment.remoteControl.message?.header, "Kitchen")
        XCTAssertEqual(environment.remoteControl.message?.text, "Dinner is ready")
        XCTAssertEqual(environment.remoteControl.message?.timeout, 4)
        environment.remoteGeneral(GeneralCommand(name: "SetVolume", arguments: ["Volume": "50"]))
        XCTAssertEqual(environment.remoteControl.message?.text, "Dinner is ready", "unsupported commands are logged, not shown")
    }
}
