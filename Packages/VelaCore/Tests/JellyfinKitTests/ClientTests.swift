import XCTest
@testable import JellyfinKit
import VelaFoundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Records requests and serves canned responses keyed by path.
final class MockTransport: HTTPTransport, @unchecked Sendable {
    struct Response {
        var status: Int
        var body: Data
    }

    private let lock = NSLock()
    private(set) var requests: [URLRequest] = []
    var responses: [String: Response] = [:]
    var fallback = Response(status: 404, body: Data())

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let response = record(request)
        let http = HTTPURLResponse(url: request.url!, statusCode: response.status, httpVersion: nil, headerFields: nil)!
        return (response.body, http)
    }

    private func record(_ request: URLRequest) -> Response {
        lock.lock()
        defer { lock.unlock() }
        requests.append(request)
        let path = request.url?.path ?? ""
        return responses[path] ?? fallback
    }

    func set(_ path: String, status: Int = 200, json: String) {
        responses[path] = Response(status: status, body: json.data(using: .utf8)!)
    }
}

final class ServerAddressTests: XCTestCase {
    func testPlainHostGetsBothSchemes() {
        let urls = ServerAddress.candidates(for: " 192.168.1.10:8096/ ")
        XCTAssertEqual(urls.map(\.absoluteString), ["https://192.168.1.10:8096", "http://192.168.1.10:8096"])
    }

    func testExplicitSchemeIsKept() {
        XCTAssertEqual(ServerAddress.candidates(for: "http://nas.local:8096").map(\.absoluteString), ["http://nas.local:8096"])
        XCTAssertEqual(ServerAddress.candidates(for: "HTTPS://media.example.com/jellyfin/").map(\.absoluteString), ["https://media.example.com/jellyfin"])
    }

    func testInvalidInput() {
        XCTAssertTrue(ServerAddress.candidates(for: "").isEmpty)
        XCTAssertTrue(ServerAddress.candidates(for: "ftp://x").isEmpty)
        XCTAssertTrue(ServerAddress.candidates(for: "https://").isEmpty)
    }
}

final class ClientTests: XCTestCase {
    func makeClient(base: String = "https://media.example.com", token: String? = "tok", userId: String? = "user1") -> (JellyfinClient, MockTransport) {
        let transport = MockTransport()
        let client = JellyfinClient(baseURL: URL(string: base)!, identity: DeviceIdentity(deviceId: "dev1", version: "1.2"),
                                    transport: transport, accessToken: token, userId: userId)
        return (client, transport)
    }

    func testAuthorizationHeader() throws {
        let (client, _) = makeClient()
        let request = try client.makeRequest(.get("/Users/Me"))
        let header = try XCTUnwrap(request.value(forHTTPHeaderField: "Authorization"))
        XCTAssertEqual(header, "MediaBrowser Client=\"Vela\", Device=\"Apple TV\", DeviceId=\"dev1\", Version=\"1.2\", Token=\"tok\"")
        let anonymous = try client.makeRequest(.get("/System/Info/Public", requiresAuthentication: false))
        XCTAssertFalse(anonymous.value(forHTTPHeaderField: "Authorization")!.contains("Token"))
    }

    func testURLBuildingWithBasePath() throws {
        let (client, _) = makeClient(base: "https://host.example/jellyfin")
        XCTAssertEqual(client.url(for: "/Items", query: [URLQueryItem(name: "a", value: "1")])?.absoluteString, "https://host.example/jellyfin/Items?a=1")
        // TranscodingUrl already prefixed with the base path and carrying a query string.
        let transcoding = client.transcodingURL(path: "/jellyfin/videos/1/master.m3u8?DeviceId=d&api_key=tok")
        XCTAssertEqual(transcoding?.absoluteString, "https://host.example/jellyfin/videos/1/master.m3u8?DeviceId=d&api_key=tok")
        let plain = client.transcodingURL(path: "/videos/1/master.m3u8?DeviceId=d")
        XCTAssertEqual(plain?.absoluteString, "https://host.example/jellyfin/videos/1/master.m3u8?DeviceId=d&ApiKey=tok&api_key=tok")
    }

    func testMediaURLsCarryToken() throws {
        let (client, _) = makeClient()
        let stream = try XCTUnwrap(client.directStreamURL(itemId: "i1", mediaSourceId: "ms1", playSessionId: "ps", eTag: "e", container: "mkv"))
        let components = URLComponents(url: stream, resolvingAgainstBaseURL: false)!
        XCTAssertEqual(components.path, "/Videos/i1/stream.mkv")
        let items = Dictionary(uniqueKeysWithValues: components.queryItems!.map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(items["static"], "true")
        XCTAssertEqual(items["mediaSourceId"], "ms1")
        XCTAssertEqual(items["api_key"], "tok")
        XCTAssertEqual(items["playSessionId"], "ps")
        XCTAssertEqual(items["Tag"], "e")

        let subtitle = client.subtitleURL(itemId: "i1", mediaSourceId: "ms1", streamIndex: 5, format: "srt")
        XCTAssertEqual(subtitle?.absoluteString, "https://media.example.com/Videos/i1/ms1/Subtitles/5/0/Stream.srt?ApiKey=tok&api_key=tok")
        let delivered = client.subtitleURL(itemId: "i1", mediaSourceId: "ms1", streamIndex: 5, format: "srt", deliveryUrl: "/Videos/i1/ms1/Subtitles/5/0/Stream.srt?api_key=tok")
        XCTAssertEqual(delivered?.absoluteString, "https://media.example.com/Videos/i1/ms1/Subtitles/5/0/Stream.srt?api_key=tok")

        let image = client.imageURL(itemId: "i1", type: .primary, tag: "t", maxWidth: 400)
        XCTAssertEqual(image?.absoluteString, "https://media.example.com/Items/i1/Images/Primary?quality=90&tag=t&maxWidth=400")
        let trick = client.trickplayTileURL(itemId: "i1", width: 320, tileIndex: 3, mediaSourceId: "ms1")
        XCTAssertEqual(trick?.absoluteString, "https://media.example.com/Videos/i1/Trickplay/320/3.jpg?mediaSourceId=ms1&ApiKey=tok&api_key=tok")
    }

    func testLoginStoresToken() async throws {
        let (client, transport) = makeClient(token: nil, userId: nil)
        transport.set("/Users/AuthenticateByName", json: String(decoding: try fixture("auth_result"), as: UTF8.self))
        let result = try await client.authenticate(username: "anna", password: "pw")
        XCTAssertEqual(result.accessToken, "tok_ABC")
        XCTAssertEqual(client.accessToken, "tok_ABC")
        XCTAssertEqual(client.userId, "user1")
        XCTAssertTrue(client.isAuthenticated)
        let request = try XCTUnwrap(transport.requests.first)
        XCTAssertEqual(request.httpMethod, "POST")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: request.httpBody!) as? [String: Any])
        XCTAssertEqual(body["Username"] as? String, "anna")
        XCTAssertEqual(body["Pw"] as? String, "pw")
    }

    func testUnauthorizedMapsToErrors() async throws {
        let (client, transport) = makeClient(token: nil, userId: nil)
        transport.set("/Users/AuthenticateByName", status: 401, json: "")
        do {
            _ = try await client.authenticate(username: "a", password: "b")
            XCTFail("expected failure")
        } catch let error as VelaError {
            XCTAssertEqual(error.kind, .authenticationFailed)
        }

        let (authed, transport2) = makeClient()
        let expired = expectation(description: "expired callback")
        authed.onSessionExpired = { expired.fulfill() }
        transport2.set("/Users/Me", status: 401, json: "")
        do {
            _ = try await authed.currentUser()
            XCTFail("expected failure")
        } catch let error as VelaError {
            XCTAssertEqual(error.kind, .sessionExpired)
        }
        await fulfillment(of: [expired], timeout: 1)
    }

    func testLegacyFallbackForResume() async throws {
        let (client, transport) = makeClient()
        transport.set("/Users/user1/Items/Resume", json: String(decoding: try fixture("resume_items"), as: UTF8.self))
        let items = try await client.resumeItems()
        XCTAssertEqual(items.count, 2)
        XCTAssertEqual(transport.requests.map { $0.url!.path }, ["/UserItems/Resume", "/Users/user1/Items/Resume"])
    }

    func testMediaSegmentsFallbackChain() async throws {
        let (client, transport) = makeClient()
        // No MediaSegments endpoint, no new plugin endpoint, legacy plugin present.
        transport.set("/Episode/ep1/IntroTimestamps/v1", json: String(decoding: try fixture("intro_skipper"), as: UTF8.self))
        let segments = try await client.mediaSegments(itemId: "ep1")
        XCTAssertEqual(segments.count, 1)
        XCTAssertEqual(segments.first?.type, .intro)

        let (client2, transport2) = makeClient()
        transport2.set("/MediaSegments/ep1", json: String(decoding: try fixture("media_segments"), as: UTF8.self))
        let native = try await client2.mediaSegments(itemId: "ep1")
        XCTAssertEqual(native.map(\.type), [.intro, .outro])
        XCTAssertEqual(transport2.requests.count, 1)
        let query = URLComponents(url: transport2.requests[0].url!, resolvingAgainstBaseURL: false)!.queryItems!
        XCTAssertTrue(query.contains(URLQueryItem(name: "includeSegmentTypes", value: "Intro")))
    }

    func testItemsQueryEncoding() {
        var query = ItemsQuery(parentId: "lib1", includeItemTypes: [.movie], sortBy: [.dateCreated], sortOrder: .descending, startIndex: 100, limit: 50)
        query.filters = [.isUnplayed]
        let dict = Dictionary(uniqueKeysWithValues: query.queryItems.map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(dict["ParentId"], "lib1")
        XCTAssertEqual(dict["IncludeItemTypes"], "Movie")
        XCTAssertEqual(dict["SortBy"], "DateCreated")
        XCTAssertEqual(dict["SortOrder"], "Descending")
        XCTAssertEqual(dict["StartIndex"], "100")
        XCTAssertEqual(dict["Limit"], "50")
        XCTAssertEqual(dict["Filters"], "IsUnplayed")
        XCTAssertEqual(dict["Recursive"], "true")
        XCTAssertNil(dict["SearchTerm"])
    }

    func testServerErrorsAndDecodeErrors() async throws {
        let (client, transport) = makeClient()
        transport.set("/Users/Me", status: 500, json: "boom")
        do {
            _ = try await client.currentUser()
            XCTFail()
        } catch let error as VelaError {
            XCTAssertEqual(error.kind, .serverError(status: 500))
        }
        transport.set("/Users/Me", status: 200, json: "not json")
        do {
            _ = try await client.currentUser()
            XCTFail()
        } catch let error as VelaError {
            if case .serverError = error.kind {} else { XCTFail("unexpected \(error)") }
        }
    }
}
