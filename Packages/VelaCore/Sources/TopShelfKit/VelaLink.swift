import Foundation

/// Deep links into the app (`vela://item/<id>`, `vela://play/<id>`). The Top Shelf hands these
/// to tvOS; the app receives them through `onOpenURL`.
public enum VelaLink: Hashable, Sendable {
    /// Opens the detail screen of an item.
    case item(id: String)
    /// Starts playback, resuming where the server has a position.
    case play(id: String)

    public static let scheme = "vela"

    public var itemId: String {
        switch self {
        case .item(let id), .play(let id): id
        }
    }

    private var host: String {
        switch self {
        case .item: "item"
        case .play: "play"
        }
    }

    public var url: URL {
        var components = URLComponents()
        components.scheme = Self.scheme
        components.host = host
        components.path = "/" + itemId
        return components.url!
    }

    public init?(url: URL) {
        guard url.scheme?.lowercased() == Self.scheme,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        let id = components.path.split(separator: "/").first.map(String.init) ?? ""
        guard !id.isEmpty else { return nil }
        switch components.host?.lowercased() {
        case "item": self = .item(id: id)
        case "play": self = .play(id: id)
        default: return nil
        }
    }
}
