import XCTest
import JellyfinKit
@testable import TopShelfKit
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Serves canned JSON keyed by request path; unknown paths get 404.
private final class StubTransport: HTTPTransport, @unchecked Sendable {
    var responses: [String: (Int, String)] = [:]

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (status, body) = responses[request.url?.path ?? ""] ?? (404, "")
        return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }
}

private func items(_ json: String) -> [BaseItem] {
    try! JellyfinDate.makeDecoder().decode([BaseItem].self, from: Data(json.utf8))
}

private let resumeJSON = """
[
  {"Id": "ep1", "Name": "Pilot", "Type": "Episode", "SeriesName": "The Expanse", "SeriesId": "s1", "IndexNumber": 1, "ParentIndexNumber": 1,
   "ImageTags": {"Primary": "p1"}, "UserData": {"PlaybackPositionTicks": 9000000000, "PlayedPercentage": 25}},
  {"Id": "mv1", "Name": "Heat", "Type": "Movie", "BackdropImageTags": ["b1"], "UserData": {"PlayedPercentage": 50}}
]
"""

private let nextUpJSON = """
[
  {"Id": "ep1", "Name": "Pilot", "Type": "Episode", "SeriesName": "The Expanse", "IndexNumber": 1, "ParentIndexNumber": 1},
  {"Id": "ep9", "Name": "Fresh", "Type": "Episode", "SeriesName": "Severance", "IndexNumber": 2, "ParentIndexNumber": 2}
]
"""

final class VelaLinkTests: XCTestCase {
    func testRoundTrip() {
        for link in [VelaLink.item(id: "abc123"), .play(id: "f00d")] {
            XCTAssertEqual(VelaLink(url: link.url), link)
        }
        XCTAssertEqual(VelaLink.play(id: "f00d").url.absoluteString, "vela://play/f00d")
    }

    func testRejectsForeignURLs() {
        XCTAssertNil(VelaLink(url: URL(string: "https://item/abc")!))
        XCTAssertNil(VelaLink(url: URL(string: "vela://item/")!))
        XCTAssertNil(VelaLink(url: URL(string: "vela://settings/x")!))
    }
}

final class TopShelfBuilderTests: XCTestCase {
    private let images = ItemImages(client: JellyfinClient(baseURL: URL(string: "http://jf.local:8096")!,
                                                           identity: DeviceIdentity(deviceId: "d"), transport: StubTransport()))

    func testContinueWatchingMergesResumeAndNextUpWithoutDuplicates() {
        let snapshot = TopShelfBuilder.snapshot(accountId: "a", resume: items(resumeJSON), nextUp: items(nextUpJSON), latest: [], images: images)
        XCTAssertEqual(snapshot.sections.map(\.kind), [.continueWatching])
        let entries = snapshot.sections[0].entries
        XCTAssertEqual(entries.map(\.id), ["ep1", "mv1", "ep9"])
        XCTAssertEqual(entries.map(\.title), ["The Expanse · S1 · E1", "Heat", "Severance · S2 · E2"])
        XCTAssertEqual(entries[0].progress, 0.25)
        XCTAssertNil(entries[2].progress)
        XCTAssertEqual(entries[0].displayURL, VelaLink.play(id: "ep1").url)
        XCTAssertEqual(entries[0].imageURL2x?.absoluteString, "http://jf.local:8096/Items/ep1/Images/Primary?quality=90&tag=p1&maxWidth=1120")
        XCTAssertEqual(entries[1].imageURL1x?.path, "/Items/mv1/Images/Backdrop/0")
    }

    func testRecentlyAddedInterleavesLibrariesAndSkipsContinueItems() {
        let movies = items(#"[{"Id": "mv1", "Name": "Heat", "Type": "Movie"}, {"Id": "mv2", "Name": "Ronin", "Type": "Movie", "ImageTags": {"Primary": "r"}}]"#)
        let shows = items(#"[{"Id": "s7", "Name": "Andor", "Type": "Series"}]"#)
        let snapshot = TopShelfBuilder.snapshot(accountId: "a", resume: items(resumeJSON), nextUp: [], latest: [movies, shows], images: images)
        let latest = snapshot.sections.first { $0.kind == .recentlyAdded }
        XCTAssertEqual(latest?.shape, .poster)
        XCTAssertEqual(latest?.entries.map(\.id), ["s7", "mv2"])
        XCTAssertEqual(latest?.entries[0].displayURL, VelaLink.item(id: "s7").url)
        XCTAssertNil(latest?.entries[0].playURL, "a series has nothing to play directly")
        XCTAssertEqual(latest?.entries[1].playURL, VelaLink.play(id: "mv2").url)
    }

    func testLimits() {
        let many = items("[" + (0..<30).map { #"{"Id": "m\#($0)", "Name": "M\#($0)", "Type": "Movie"}"# }.joined(separator: ",") + "]")
        let snapshot = TopShelfBuilder.snapshot(accountId: "a", resume: many, nextUp: [], latest: [many], images: images)
        XCTAssertEqual(snapshot.sections[0].entries.count, TopShelfBuilder.continueLimit)
        XCTAssertEqual(snapshot.sections[1].entries.count, TopShelfBuilder.recentlyAddedLimit)
        XCTAssertEqual(snapshot.sections[1].entries.first?.id, "m10")
    }

    func testEmpty() {
        XCTAssertTrue(TopShelfBuilder.snapshot(accountId: "a", resume: [], nextUp: [], latest: [[]], images: images).isEmpty)
    }
}

final class TopShelfLoaderTests: XCTestCase {
    func testLoadsFromServer() async throws {
        let transport = StubTransport()
        transport.responses = [
            "/UserItems/Resume": (200, #"{"Items": \#(resumeJSON)}"#),
            "/Shows/NextUp": (200, #"{"Items": \#(nextUpJSON)}"#),
            "/UserViews": (200, #"{"Items": [{"Id": "lib-m", "Name": "Filme", "CollectionType": "movies"}, {"Id": "lib-music", "Name": "Musik", "CollectionType": "music"}]}"#),
            "/Items/Latest": (200, #"[{"Id": "mv5", "Name": "Alien", "Type": "Movie"}]"#),
        ]
        let client = JellyfinClient(baseURL: URL(string: "http://jf.local")!, identity: DeviceIdentity(deviceId: "d"), transport: transport,
                                    accessToken: "t", userId: "u")
        let snapshot = try await TopShelfLoader.load(client: client, accountId: "acc")
        XCTAssertEqual(snapshot.accountId, "acc")
        XCTAssertEqual(snapshot.sections.map { $0.entries.map(\.id) }, [["ep1", "mv1", "ep9"], ["mv5"]])
    }

    func testFailsWhenResumeFails() async {
        let client = JellyfinClient(baseURL: URL(string: "http://jf.local")!, identity: DeviceIdentity(deviceId: "d"), transport: StubTransport(),
                                    accessToken: "t", userId: "u")
        do {
            _ = try await TopShelfLoader.load(client: client, accountId: "acc")
            XCTFail("expected an error")
        } catch {}
    }
}

final class TopShelfStoreTests: XCTestCase {
    func testAccountSwitchDropsSnapshot() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = TopShelfStore(directory: dir)
        let account = TopShelfStore.Account(accountId: "a", serverURL: URL(string: "http://jf")!, userId: "u", tokenKey: "token.a",
                                            deviceId: "d", deviceName: "Wohnzimmer", clientVersion: "1.0")
        XCTAssertNil(store.loadSnapshot())
        store.saveAccount(account)
        let snapshot = TopShelfSnapshot(accountId: "a", created: Date(timeIntervalSince1970: 0), sections: [])
        store.saveSnapshot(snapshot)
        XCTAssertEqual(store.loadSnapshot(), snapshot)

        store.saveAccount(account) // same account: snapshot stays
        XCTAssertEqual(store.loadSnapshot(), snapshot)

        var other = account
        other.accountId = "b"
        store.saveAccount(other)
        XCTAssertNil(store.loadSnapshot())
        XCTAssertEqual(store.loadAccount(), other)

        store.saveAccount(nil)
        XCTAssertNil(store.loadAccount())
    }
}
