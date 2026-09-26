import Foundation
import FoyerFoundation

/// Normalises what a user types into a list of candidate base URLs.
///
/// Rules:
/// - explicit scheme is respected (http stays http, https stays https)
/// - no scheme: try https first, then http (local servers are commonly plain http on 8096)
/// - trailing slashes and whitespace are removed; a path prefix like `/jellyfin` is kept
public enum ServerAddress {
    public static func candidates(for input: String) -> [URL] {
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return [] }
        while text.hasSuffix("/") { text.removeLast() }
        text = text.replacingOccurrences(of: " ", with: "")

        let lower = text.lowercased()
        let hasScheme = lower.hasPrefix("http://") || lower.hasPrefix("https://")
        // Any other scheme (ftp://, smb://, ...) is not a Jellyfin server.
        if !hasScheme, lower.contains("://") { return [] }
        var results: [URL] = []

        if hasScheme {
            if let url = validate(text) { results.append(url) }
        } else {
            if let https = validate("https://" + text) { results.append(https) }
            if let http = validate("http://" + text) { results.append(http) }
        }
        return results
    }

    private static func validate(_ string: String) -> URL? {
        guard var components = URLComponents(string: string) else { return nil }
        guard let host = components.host, !host.isEmpty, host != "http", host != "https" else { return nil }
        guard let scheme = components.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return nil }
        if components.path.contains("//") { return nil }
        components.scheme = scheme
        components.query = nil
        components.fragment = nil
        if components.path.hasSuffix("/") {
            components.path = String(components.path.dropLast())
        }
        return components.url
    }

    /// Human-friendly form for display ("https://media.example.com").
    public static func display(_ url: URL) -> String {
        var s = url.absoluteString
        while s.hasSuffix("/") { s.removeLast() }
        return s
    }
}
