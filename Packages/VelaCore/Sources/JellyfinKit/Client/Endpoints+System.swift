import Foundation
import VelaFoundation

public extension JellyfinClient {
    /// Unauthenticated ping used when adding a server.
    func publicSystemInfo() async throws -> PublicSystemInfo {
        try await send(.get("/System/Info/Public", requiresAuthentication: false))
    }

    func publicUsers() async throws -> [User] {
        try await send(.get("/Users/Public", requiresAuthentication: false))
    }

    func authenticate(username: String, password: String) async throws -> AuthenticationResult {
        struct Body: Encodable {
            let Username: String
            let Pw: String
        }
        let endpoint = try Endpoint.post("/Users/AuthenticateByName", json: Body(Username: username, Pw: password), requiresAuthentication: false)
        let result: AuthenticationResult = try await send(endpoint)
        accessToken = result.accessToken
        userId = result.user.id
        return result
    }

    func currentUser() async throws -> User {
        try await send(.get("/Users/Me"))
    }

    func logout() async throws {
        try await send(try Endpoint.post("/Sessions/Logout"))
        accessToken = nil
        userId = nil
    }

    func postCapabilities(_ capabilities: ClientCapabilities) async throws {
        try await send(try Endpoint.post("/Sessions/Capabilities/Full", json: capabilities))
    }

    // MARK: Quick Connect

    func quickConnectEnabled() async throws -> Bool {
        let data = try await send(.get("/QuickConnect/Enabled", requiresAuthentication: false))
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "true"
    }

    func quickConnectInitiate() async throws -> QuickConnectResult {
        // 10.9+ uses POST; older servers used GET.
        do {
            return try await send(try Endpoint.post("/QuickConnect/Initiate", requiresAuthentication: false))
        } catch let error as VelaError {
            if case .serverError(let status) = error.kind, status == 405 {
                return try await send(.get("/QuickConnect/Initiate", requiresAuthentication: false))
            }
            if error.kind == .notFound {
                return try await send(.get("/QuickConnect/Initiate", requiresAuthentication: false))
            }
            throw error
        }
    }

    func quickConnectState(secret: String) async throws -> QuickConnectResult {
        try await send(.get("/QuickConnect/Connect", query: [URLQueryItem(name: "secret", value: secret)], requiresAuthentication: false))
    }

    func authenticateWithQuickConnect(secret: String) async throws -> AuthenticationResult {
        struct Body: Encodable { let Secret: String }
        let result: AuthenticationResult = try await send(try Endpoint.post("/Users/AuthenticateWithQuickConnect", json: Body(Secret: secret), requiresAuthentication: false))
        accessToken = result.accessToken
        userId = result.user.id
        return result
    }
}
