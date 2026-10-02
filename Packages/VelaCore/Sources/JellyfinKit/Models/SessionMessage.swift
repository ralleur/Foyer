import Foundation

/// A command relayed by the server's session WebSocket (`/socket`). Jellyfin's web UI, the apps and
/// the dashboard send these when a user picks this device under "Play on" or remote-controls it.
public enum RemoteCommand: Sendable, Equatable {
    case play(RemotePlayRequest)
    case playState(PlayStateCommand, seekPositionTicks: Int64?)
    case general(GeneralCommand)
}

/// `Play` message payload. Item ids are normalised to Jellyfin's compact form (32 hex digits, lowercase).
public struct RemotePlayRequest: Sendable, Equatable {
    public enum Mode: String, Sendable {
        case playNow = "PlayNow"
        case playNext = "PlayNext"
        case playLast = "PlayLast"
        case playInstantMix = "PlayInstantMix"
        case playShuffle = "PlayShuffle"
    }

    public var itemIds: [String]
    public var mode: Mode
    public var startPositionTicks: Int64?
    public var startIndex: Int
    public var mediaSourceId: String?
    public var audioStreamIndex: Int?
    public var subtitleStreamIndex: Int?
    public var controllingUserId: String?

    public init(itemIds: [String], mode: Mode = .playNow, startPositionTicks: Int64? = nil, startIndex: Int = 0,
                mediaSourceId: String? = nil, audioStreamIndex: Int? = nil, subtitleStreamIndex: Int? = nil, controllingUserId: String? = nil) {
        self.itemIds = itemIds
        self.mode = mode
        self.startPositionTicks = startPositionTicks
        self.startIndex = startIndex
        self.mediaSourceId = mediaSourceId
        self.audioStreamIndex = audioStreamIndex
        self.subtitleStreamIndex = subtitleStreamIndex
        self.controllingUserId = controllingUserId
    }

    public var startPosition: TimeInterval? { startPositionTicks.map { Double($0) / 10_000_000 } }

    /// The item to start with (`StartIndex` into `ItemIds`).
    public var firstItemId: String? { itemIds.indices.contains(startIndex) ? itemIds[startIndex] : itemIds.first }
}

/// `Playstate` message commands (Jellyfin `PlaystateCommand`).
public enum PlayStateCommand: String, Sendable, CaseIterable {
    case stop = "Stop"
    case pause = "Pause"
    case unpause = "Unpause"
    case nextTrack = "NextTrack"
    case previousTrack = "PreviousTrack"
    case seek = "Seek"
    case rewind = "Rewind"
    case fastForward = "FastForward"
    case playPause = "PlayPause"
}

/// `GeneralCommand` message payload (`DisplayMessage`, `SetAudioStreamIndex`, …). Argument values arrive as strings.
public struct GeneralCommand: Sendable, Equatable {
    public var name: String
    public var arguments: [String: String]
    public var controllingUserId: String?

    public init(name: String, arguments: [String: String] = [:], controllingUserId: String? = nil) {
        self.name = name
        self.arguments = arguments
        self.controllingUserId = controllingUserId
    }

    public func argument(_ key: String) -> String? {
        arguments.first { $0.key.caseInsensitiveCompare(key) == .orderedSame }?.value
    }
}

/// One frame of the session WebSocket protocol: `{"MessageType": "...", "Data": ...}`.
public enum SessionMessage: Sendable, Equatable {
    /// The server asks the client to send `KeepAlive` frames; the payload is its timeout in seconds.
    case forceKeepAlive(timeoutSeconds: Int)
    case keepAlive
    case command(RemoteCommand)
    /// Notifications the app does not act on (`UserDataChanged`, `LibraryChanged`, …).
    case other(type: String)

    public static let keepAliveFrame = #"{"MessageType":"KeepAlive"}"#

    public static func parse(_ data: Data) -> SessionMessage? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = object["MessageType"] as? String else { return nil }
        let payload = object["Data"]
        switch type.lowercased() {
        case "forcekeepalive":
            return .forceKeepAlive(timeoutSeconds: int(payload) ?? 60)
        case "keepalive":
            return .keepAlive
        case "play":
            guard let dict = payload as? [String: Any] else { return nil }
            let ids = ((dict["ItemIds"] as? [Any]) ?? []).compactMap { $0 as? String }.map(normalizeId)
            let request = RemotePlayRequest(itemIds: ids,
                                            mode: (dict["PlayCommand"] as? String).flatMap(RemotePlayRequest.Mode.init(rawValue:)) ?? .playNow,
                                            startPositionTicks: int64(dict["StartPositionTicks"]),
                                            startIndex: int(dict["StartIndex"]) ?? 0,
                                            mediaSourceId: dict["MediaSourceId"] as? String,
                                            audioStreamIndex: int(dict["AudioStreamIndex"]),
                                            subtitleStreamIndex: int(dict["SubtitleStreamIndex"]),
                                            controllingUserId: dict["ControllingUserId"] as? String)
            return .command(.play(request))
        case "playstate":
            guard let dict = payload as? [String: Any], let name = dict["Command"] as? String,
                  let command = PlayStateCommand.allCases.first(where: { $0.rawValue.caseInsensitiveCompare(name) == .orderedSame }) else { return nil }
            return .command(.playState(command, seekPositionTicks: int64(dict["SeekPositionTicks"])))
        case "generalcommand":
            guard let dict = payload as? [String: Any], let name = dict["Name"] as? String else { return nil }
            var arguments: [String: String] = [:]
            for (key, value) in (dict["Arguments"] as? [String: Any]) ?? [:] {
                switch value {
                case let string as String: arguments[key] = string
                case is NSNull: break
                default: arguments[key] = String(describing: value)
                }
            }
            return .command(.general(GeneralCommand(name: name, arguments: arguments, controllingUserId: dict["ControllingUserId"] as? String)))
        default:
            return .other(type: type)
        }
    }

    /// Jellyfin sends GUIDs with dashes on the socket but compact ids everywhere else.
    static func normalizeId(_ id: String) -> String {
        id.replacingOccurrences(of: "-", with: "").lowercased()
    }

    private static func int(_ value: Any?) -> Int? {
        switch value {
        case let number as Int: return number
        case let number as Double: return Int(number)
        case let number as NSNumber: return number.intValue
        case let string as String: return Int(string)
        default: return nil
        }
    }

    private static func int64(_ value: Any?) -> Int64? {
        switch value {
        case let number as Int64: return number
        case let number as Int: return Int64(number)
        case let number as Double: return Int64(number)
        case let number as NSNumber: return number.int64Value
        case let string as String: return Int64(string)
        default: return nil
        }
    }
}

public extension JellyfinClient {
    /// `ws(s)://…/socket?deviceId=…` for the session WebSocket; nil when signed out.
    /// The token travels in the `Authorization` header (see `webSocketRequest`): Jellyfin 10.11 answers
    /// `api_key` in the query of this endpoint with 403 "Token is required".
    func webSocketURL() -> URL? {
        guard accessToken != nil,
              let http = url(for: "/socket", query: [URLQueryItem(name: "deviceId", value: identity.deviceId)]),
              var components = URLComponents(url: http, resolvingAgainstBaseURL: false) else { return nil }
        components.scheme = http.scheme?.lowercased() == "https" ? "wss" : "ws"
        return components.url
    }

    /// The upgrade request for the session WebSocket with the usual `MediaBrowser … Token=` header.
    func webSocketRequest() -> URLRequest? {
        guard let url = webSocketURL() else { return nil }
        var request = URLRequest(url: url)
        request.setValue(identity.authorizationHeader(token: accessToken), forHTTPHeaderField: "Authorization")
        return request
    }
}
