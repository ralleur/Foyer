import XCTest
@testable import JellyfinKit
import FoyerFoundation

final class SessionMessageTests: XCTestCase {
    private func parse(_ json: String) -> SessionMessage? { SessionMessage.parse(Data(json.utf8)) }

    func test_play_normalisesIdsAndReadsOptions() throws {
        let message = parse(#"""
        {"MessageType":"Play","Data":{"ItemIds":["D96D7047-6839-4399-A629-14D1A92810B0","aa11"],"StartPositionTicks":150000000,
         "PlayCommand":"PlayNow","ControllingUserId":"u1","MediaSourceId":"src","AudioStreamIndex":2,"SubtitleStreamIndex":-1,"StartIndex":1},"MessageId":"x"}
        """#)
        guard case let .command(.play(request)) = message else { return XCTFail("\(String(describing: message))") }
        XCTAssertEqual(request.itemIds, ["d96d704768394399a62914d1a92810b0", "aa11"])
        XCTAssertEqual(request.firstItemId, "aa11", "StartIndex picks the item")
        XCTAssertEqual(request.startPosition, 15)
        XCTAssertEqual(request.mode, .playNow)
        XCTAssertEqual(request.mediaSourceId, "src")
        XCTAssertEqual(request.audioStreamIndex, 2)
        XCTAssertEqual(request.subtitleStreamIndex, -1)
        XCTAssertEqual(request.controllingUserId, "u1")
    }

    func test_play_withoutOptionalFields() throws {
        let message = parse(#"{"MessageType":"Play","Data":{"ItemIds":["aa11"],"PlayCommand":"PlayNext"}}"#)
        guard case let .command(.play(request)) = message else { return XCTFail() }
        XCTAssertNil(request.startPositionTicks)
        XCTAssertNil(request.startPosition)
        XCTAssertEqual(request.mode, .playNext)
        XCTAssertEqual(request.firstItemId, "aa11")
    }

    func test_playstate_seekAndPause() throws {
        XCTAssertEqual(parse(#"{"MessageType":"Playstate","Data":{"Command":"Seek","SeekPositionTicks":30000000,"ControllingUserId":"u"}}"#),
                       .command(.playState(.seek, seekPositionTicks: 30_000_000)))
        XCTAssertEqual(parse(#"{"MessageType":"Playstate","Data":{"Command":"Pause","SeekPositionTicks":null}}"#),
                       .command(.playState(.pause, seekPositionTicks: nil)))
        XCTAssertNil(parse(#"{"MessageType":"Playstate","Data":{"Command":"Levitate"}}"#), "unknown play-state commands are dropped")
    }

    func test_generalCommand_argumentsAreStrings() throws {
        let message = parse(#"{"MessageType":"GeneralCommand","Data":{"Name":"DisplayMessage","Arguments":{"Header":"Hi","Text":"Dinner","TimeoutMs":"4000"},"ControllingUserId":"u"}}"#)
        guard case let .command(.general(command)) = message else { return XCTFail() }
        XCTAssertEqual(command.name, "DisplayMessage")
        XCTAssertEqual(command.argument("text"), "Dinner", "argument lookup ignores case")
        XCTAssertEqual(command.argument("TimeoutMs"), "4000")
        let index = parse(#"{"MessageType":"GeneralCommand","Data":{"Name":"SetAudioStreamIndex","Arguments":{"Index":1}}}"#)
        guard case let .command(.general(setAudio)) = index else { return XCTFail() }
        XCTAssertEqual(setAudio.argument("Index"), "1", "numbers are stringified")
    }

    func test_keepAliveAndOthers() {
        XCTAssertEqual(parse(#"{"MessageType":"ForceKeepAlive","Data":60}"#), .forceKeepAlive(timeoutSeconds: 60))
        XCTAssertEqual(parse(#"{"MessageType":"KeepAlive"}"#), .keepAlive)
        XCTAssertEqual(parse(#"{"MessageType":"UserDataChanged","Data":{"UserId":"u"}}"#), .other(type: "UserDataChanged"))
        XCTAssertNil(parse("not json"))
        XCTAssertNil(parse(#"{"Data":1}"#))
    }

    func test_webSocketURL() {
        let identity = DeviceIdentity(deviceId: "dev-1")
        let plain = JellyfinClient(baseURL: URL(string: "http://server:8096")!, identity: identity, transport: MockTransport(), accessToken: "tok", userId: "u")
        XCTAssertEqual(plain.webSocketURL()?.absoluteString, "ws://server:8096/socket?deviceId=dev-1")
        let proxied = JellyfinClient(baseURL: URL(string: "https://media.example.com/jellyfin")!, identity: identity, transport: MockTransport(), accessToken: "tok", userId: "u")
        XCTAssertEqual(proxied.webSocketURL()?.absoluteString, "wss://media.example.com/jellyfin/socket?deviceId=dev-1")
        let request = proxied.webSocketRequest()
        XCTAssertEqual(request?.url?.scheme, "wss")
        XCTAssertTrue(request?.value(forHTTPHeaderField: "Authorization")?.contains("Token=\"tok\"") == true, "token goes in the header, not the query")
        XCTAssertFalse(request?.url?.query?.contains("api_key") == true)
        let signedOut = JellyfinClient(baseURL: URL(string: "http://server:8096")!, identity: identity, transport: MockTransport())
        XCTAssertNil(signedOut.webSocketURL())
        XCTAssertNil(signedOut.webSocketRequest())
    }
}
