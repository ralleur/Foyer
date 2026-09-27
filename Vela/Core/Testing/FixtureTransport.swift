import Foundation
import VelaFoundation
import JellyfinKit

/// Serves bundled JSON for UI tests (launch argument `-uitest`). Never used in production.
final class FixtureTransport: HTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var log: [String] = []

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let path = request.url?.path ?? "/"
        let method = request.httpMethod ?? "GET"
        record("\(method) \(path)")
        let (status, body) = respond(method: method, path: path, query: request.url?.query ?? "")
        let url = request.url ?? URL(string: "https://uitest.local")!
        guard let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"]) else {
            throw URLError(.badServerResponse)
        }
        return (body, response)
    }

    private func record(_ line: String) {
        lock.lock()
        log.append(line)
        lock.unlock()
    }

    private func fixture(_ name: String) -> Data? {
        guard let url = Bundle.main.url(forResource: name, withExtension: "json", subdirectory: "UITestFixtures")
            ?? Bundle.main.url(forResource: name, withExtension: "json") else { return nil }
        return try? Data(contentsOf: url)
    }

    private func respond(method: String, path: String, query: String) -> (Int, Data) {
        let lower = path.lowercased()
        func file(_ name: String) -> (Int, Data) {
            if let data = fixture(name) { return (200, data) }
            return (404, Data())
        }
        switch true {
        case lower.hasSuffix("/system/info/public"): return file("public_system_info")
        case lower.hasSuffix("/users/public"): return file("public_users")
        case lower.hasSuffix("/users/authenticatebyname"), lower.hasSuffix("/users/authenticatewithquickconnect"): return file("auth_result")
        case lower.hasSuffix("/quickconnect/enabled"): return (200, Data("true".utf8))
        case lower.hasSuffix("/quickconnect/initiate"): return file("quick_connect")
        case lower.hasSuffix("/users/me"): return file("user")
        case lower.hasSuffix("/sessions/capabilities/full"), lower.contains("/sessions/playing"), lower.hasSuffix("/sessions/logout"): return (204, Data())
        case lower.hasSuffix("/userviews"): return file("views")
        case lower.hasSuffix("/useritems/resume"): return file("resume_items")
        case lower.hasSuffix("/shows/nextup"): return file("nextup")
        case lower.hasSuffix("/items/latest"): return file("latest")
        case lower.contains("/shows/") && lower.hasSuffix("/seasons"): return file("seasons")
        case lower.contains("/shows/") && lower.hasSuffix("/episodes"): return file("episodes")
        case lower.hasSuffix("/similar"): return file("items")
        case lower.hasSuffix("/playbackinfo"): return file("playback_info")
        case lower.contains("/mediasegments/"): return file("media_segments")
        case lower.contains("/userplayeditems/"), lower.contains("/userfavoriteitems/"): return file("userdata")
        case lower == "/items":
            if query.contains("IncludeItemTypes=Series") { return file("series_items") }
            if query.contains("SearchTerm=") { return file("items") }
            return file("items")
        case lower.hasPrefix("/items/"):
            let id = lower.split(separator: "/")[1]
            if let data = fixture("item_\(id)") { return (200, data) }
            if id == "series1" { return file("item_series1") }
            return file("movie_item")
        case lower.contains("/images/"): return (404, Data())
        default:
            Log.notice(.network, "FixtureTransport: no fixture for \(method) \(path)")
            return (404, Data())
        }
    }
}
