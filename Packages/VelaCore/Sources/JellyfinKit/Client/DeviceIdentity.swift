import Foundation

/// Identifies this client towards the Jellyfin server (shown in the dashboard).
public struct DeviceIdentity: Sendable, Hashable, Codable {
    public var clientName: String
    public var deviceName: String
    public var deviceId: String
    public var version: String

    public init(clientName: String = "Vela", deviceName: String = "Apple TV", deviceId: String, version: String = "1.0") {
        self.clientName = clientName
        self.deviceName = deviceName
        self.deviceId = deviceId
        self.version = version
    }

    /// Builds the `Authorization: MediaBrowser ...` header value.
    public func authorizationHeader(token: String?) -> String {
        var parts = [
            "Client=\"\(Self.escape(clientName))\"",
            "Device=\"\(Self.escape(deviceName))\"",
            "DeviceId=\"\(Self.escape(deviceId))\"",
            "Version=\"\(Self.escape(version))\"",
        ]
        if let token, !token.isEmpty {
            parts.append("Token=\"\(Self.escape(token))\"")
        }
        return "MediaBrowser " + parts.joined(separator: ", ")
    }

    private static func escape(_ value: String) -> String {
        value.replacingOccurrences(of: "\"", with: "'").replacingOccurrences(of: ",", with: " ")
    }
}
