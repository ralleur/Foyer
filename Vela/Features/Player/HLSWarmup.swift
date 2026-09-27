import Foundation
import VelaFoundation

/// Fetches an HLS master playlist, its first media playlist and that playlist's first segment before the
/// system player loads the URL. Jellyfin produces segments on demand; on a slow disk the first one can take
/// longer than AVPlayer is willing to wait (`-12889 No response for media file`), so Vela waits instead.
enum HLSWarmup {
    static let timeout: TimeInterval = 45

    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = timeout
        config.timeoutIntervalForResource = timeout * 2
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: config)
    }()

    static func prefetchFirstSegment(of master: URL) async {
        let started = Date()
        do {
            let masterText = try await text(master)
            guard let mediaURL = firstURI(in: masterText, relativeTo: master) else { return }
            let mediaText = try await text(mediaURL)
            var targets: [URL] = []
            if let map = mediaText.range(of: #"#EXT-X-MAP:URI="([^"]+)""#, options: .regularExpression) {
                let uri = String(mediaText[map]).replacingOccurrences(of: #"#EXT-X-MAP:URI=""#, with: "").dropLast()
                if let url = URL(string: String(uri), relativeTo: mediaURL)?.absoluteURL { targets.append(url) }
            }
            if let first = firstURI(in: mediaText, relativeTo: mediaURL) { targets.append(first) }
            for target in targets {
                var request = URLRequest(url: target)
                request.setValue("bytes=0-0", forHTTPHeaderField: "Range") // the server waits for the segment, we do not need its bytes
                _ = try await session.data(for: request)
            }
            let elapsed = Date().timeIntervalSince(started)
            if elapsed > 1.5 { Log.info(.playback, "HLS warm-up: first segment ready after \(String(format: "%.1f", elapsed)) s") }
        } catch {
            Log.notice(.playback, "HLS warm-up gave up after \(String(format: "%.1f", Date().timeIntervalSince(started))) s: \(error.localizedDescription)")
        }
    }

    private static func text(_ url: URL) async throws -> String {
        let (data, _) = try await session.data(from: url)
        return String(decoding: data, as: UTF8.self)
    }

    private static func firstURI(in playlist: String, relativeTo base: URL) -> URL? {
        for line in playlist.split(separator: "\n").map({ $0.trimmingCharacters(in: .whitespaces) }) where !line.isEmpty && !line.hasPrefix("#") {
            return URL(string: line, relativeTo: base)?.absoluteURL
        }
        return nil
    }
}
