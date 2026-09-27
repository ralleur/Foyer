import Foundation

/// A signed-in user on a server. Tokens are stored separately in the Keychain.
struct ServerAccount: Codable, Hashable, Identifiable, Sendable {
    var serverId: String
    var serverName: String
    var serverURL: URL
    var serverVersion: String?
    var userId: String
    var userName: String
    var userImageTag: String?
    var lastUsed: Date

    var id: String { "\(serverId)|\(userId)" }

    /// Keychain key for the access token.
    var tokenKey: String { "token." + id }
}

/// A server the user is about to sign in to.
struct DiscoveredServer: Hashable, Sendable {
    var url: URL
    var name: String
    var id: String
    var version: String?
    var isSecure: Bool { url.scheme?.lowercased() == "https" }
}
