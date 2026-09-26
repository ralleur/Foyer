import Foundation
import FoyerFoundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct Endpoint: Sendable {
    public enum Method: String, Sendable { case get = "GET", post = "POST", delete = "DELETE" }

    public var method: Method
    public var path: String
    public var query: [URLQueryItem]
    public var body: Data?
    public var contentType: String?
    public var requiresAuthentication: Bool

    public init(_ method: Method, _ path: String, query: [URLQueryItem] = [], body: Data? = nil,
                contentType: String? = nil, requiresAuthentication: Bool = true) {
        self.method = method
        self.path = path
        self.query = query
        self.body = body
        self.contentType = contentType
        self.requiresAuthentication = requiresAuthentication
    }

    public static func get(_ path: String, query: [URLQueryItem] = [], requiresAuthentication: Bool = true) -> Endpoint {
        Endpoint(.get, path, query: query, requiresAuthentication: requiresAuthentication)
    }

    public static func post(_ path: String, query: [URLQueryItem] = [], json: (some Encodable)? = nil as String?,
                            requiresAuthentication: Bool = true) throws -> Endpoint {
        var body: Data?
        if let json {
            body = try JellyfinDate.makeEncoder().encode(json)
        }
        return Endpoint(.post, path, query: query, body: body, contentType: body == nil ? nil : "application/json",
                        requiresAuthentication: requiresAuthentication)
    }

    public static func delete(_ path: String, query: [URLQueryItem] = []) -> Endpoint {
        Endpoint(.delete, path, query: query)
    }
}

/// Low-level Jellyfin HTTP client: builds requests, adds the MediaBrowser
/// authorization header, decodes JSON and maps failures to `FoyerError`.
///
/// Thread-safe; the access token can change (login/logout) at runtime.
public final class JellyfinClient: @unchecked Sendable {
    public let baseURL: URL
    public let identity: DeviceIdentity
    private let transport: any HTTPTransport
    private let lock = NSLock()
    private var token: String?
    private var _userId: String?
    private let decoder = JellyfinDate.makeDecoder()

    /// Called on 401 for an authenticated request (token revoked / expired).
    public var onSessionExpired: (@Sendable () -> Void)?

    public init(baseURL: URL, identity: DeviceIdentity, transport: any HTTPTransport, accessToken: String? = nil, userId: String? = nil) {
        self.baseURL = baseURL
        self.identity = identity
        self.transport = transport
        self.token = accessToken
        self._userId = userId
        if let accessToken { Log.shared.registerSecret(accessToken) }
    }

    public var accessToken: String? {
        get { lock.lock(); defer { lock.unlock() }; return token }
        set {
            lock.lock()
            if let old = token { Log.shared.removeSecret(old) }
            token = newValue
            lock.unlock()
            if let newValue { Log.shared.registerSecret(newValue) }
        }
    }

    public var userId: String? {
        get { lock.lock(); defer { lock.unlock() }; return _userId }
        set { lock.lock(); _userId = newValue; lock.unlock() }
    }

    public var isAuthenticated: Bool { accessToken != nil && userId != nil }

    // MARK: Request building

    public func url(for path: String, query: [URLQueryItem] = []) -> URL? {
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)
        let basePath = baseURL.path.hasSuffix("/") ? String(baseURL.path.dropLast()) : baseURL.path
        let relative = path.hasPrefix("/") ? path : "/" + path
        // If the server already returned an absolute path that includes the base path prefix, don't double it.
        if !basePath.isEmpty, relative.lowercased().hasPrefix(basePath.lowercased() + "/") {
            components?.path = relative
        } else {
            components?.path = basePath + relative
        }
        if let existing = URLComponents(string: "x://x" + relative)?.queryItems, !existing.isEmpty {
            // path already carries a query string (e.g. TranscodingUrl); split it off
            components?.path = String(relative.prefix { $0 != "?" })
            if !basePath.isEmpty, !relative.lowercased().hasPrefix(basePath.lowercased() + "/") {
                components?.path = basePath + String(relative.prefix { $0 != "?" })
            }
            components?.queryItems = existing + query
        } else {
            components?.queryItems = query.isEmpty ? nil : query
        }
        return components?.url
    }

    /// Appends `api_key` for URLs consumed by media players that cannot send headers.
    public func mediaURL(for path: String, query: [URLQueryItem] = []) -> URL? {
        var q = query
        if let token = accessToken, !path.lowercased().contains("api_key=") {
            q.append(URLQueryItem(name: "api_key", value: token))
        }
        return url(for: path, query: q)
    }

    public func makeRequest(_ endpoint: Endpoint) throws -> URLRequest {
        guard let url = url(for: endpoint.path, query: endpoint.query) else {
            throw FoyerError(.invalidServerAddress, detail: "Cannot build URL for \(endpoint.path)")
        }
        var request = URLRequest(url: url)
        request.httpMethod = endpoint.method.rawValue
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(identity.authorizationHeader(token: endpoint.requiresAuthentication ? accessToken : nil), forHTTPHeaderField: "Authorization")
        if let body = endpoint.body {
            request.httpBody = body
            request.setValue(endpoint.contentType ?? "application/json", forHTTPHeaderField: "Content-Type")
        }
        return request
    }

    // MARK: Sending

    @discardableResult
    public func send(_ endpoint: Endpoint) async throws -> Data {
        let request = try makeRequest(endpoint)
        let started = Date()
        let data: Data
        let response: HTTPURLResponse
        do {
            (data, response) = try await transport.send(request)
        } catch {
            let wrapped = FoyerError.wrap(error)
            Log.warning(.network, "\(endpoint.method.rawValue) \(endpoint.path) failed: \(wrapped)")
            throw wrapped
        }
        let ms = Int(Date().timeIntervalSince(started) * 1000)
        Log.debug(.network, "\(endpoint.method.rawValue) \(endpoint.path) → \(response.statusCode) (\(data.count) B, \(ms) ms)")
        try validate(response, data: data, endpoint: endpoint)
        return data
    }

    public func send<T: Decodable>(_ endpoint: Endpoint, as type: T.Type = T.self) async throws -> T {
        let data = try await send(endpoint)
        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            let snippet = String(decoding: data.prefix(300), as: UTF8.self)
            Log.error(.jellyfin, "Decoding \(T.self) for \(endpoint.path) failed: \(error). Payload: \(snippet)")
            throw FoyerError(.serverError(status: 0), detail: "Unexpected response format for \(endpoint.path): \(error)")
        }
    }

    private func validate(_ response: HTTPURLResponse, data: Data, endpoint: Endpoint) throws {
        switch response.statusCode {
        case 200..<300:
            return
        case 401:
            if endpoint.requiresAuthentication, accessToken != nil {
                Log.warning(.jellyfin, "Session rejected by server (401) for \(endpoint.path)")
                onSessionExpired?()
                throw FoyerError(.sessionExpired, detail: "HTTP 401 for \(endpoint.path)")
            }
            throw FoyerError(.authenticationFailed, detail: "HTTP 401 for \(endpoint.path)")
        case 403:
            throw FoyerError(.accessDenied, detail: "HTTP 403 for \(endpoint.path)")
        case 404:
            throw FoyerError(.notFound, detail: "HTTP 404 for \(endpoint.path)")
        default:
            let body = String(decoding: data.prefix(200), as: UTF8.self)
            throw FoyerError(.serverError(status: response.statusCode), detail: "HTTP \(response.statusCode) for \(endpoint.path): \(body)")
        }
    }

    // MARK: Helpers

    func requireUserId() throws -> String {
        guard let id = userId else {
            throw FoyerError(.sessionExpired, detail: "No user id – not signed in")
        }
        return id
    }

    /// Runs `primary`; on 404 (older server without the endpoint) runs `fallback`.
    func withLegacyFallback<T>(_ primary: () async throws -> T, fallback: () async throws -> T) async throws -> T {
        do {
            return try await primary()
        } catch let error as FoyerError where error.kind == .notFound {
            return try await fallback()
        }
    }
}
