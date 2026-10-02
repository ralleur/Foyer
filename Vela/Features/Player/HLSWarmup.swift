import Foundation
import VelaFoundation

/// Fetches an HLS master playlist, its first media playlist and the segment playback starts in before the
/// system player loads the URL. Jellyfin produces segments on demand; on a slow disk the first one can take
/// longer than AVPlayer is willing to wait (`-12889 No response for media file`), so Vela waits instead.
enum HLSWarmup {
    static let timeout: TimeInterval = 45

    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = timeout
        config.timeoutIntervalForResource = timeout * 2
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.httpAdditionalHeaders = ["User-Agent": DeviceInfo.httpUserAgent] // must match AVPlayer's (see DeviceInfo)
        return URLSession(configuration: config)
    }()

    /// Fetches the segment playback starts in. Jellyfin runs one ffmpeg per stream and restarts it for a segment
    /// far from the current one, so warming up segment 0 for a resume at 26:00 made it remux from the start, then
    /// start over (probe + seek on the source disk) when the player asked for 26:00.
    static func prefetchSegment(of master: URL, at start: TimeInterval) async {
        let started = Date()
        do {
            let masterText = try await text(master)
            guard let mediaURL = firstURI(in: masterText, relativeTo: master) else { return }
            let mediaText = try await text(mediaURL)
            // Only the media segment: it starts the server job at the right position and the job writes the
            // init segment itself.
            guard let segment = segmentURI(in: mediaText, at: start), let target = URL(string: segment, relativeTo: mediaURL)?.absoluteURL else { return }
            var request = URLRequest(url: target)
            request.setValue("bytes=0-0", forHTTPHeaderField: "Range") // the server waits for the segment, we do not need its bytes
            _ = try await session.data(for: request)
            let elapsed = Date().timeIntervalSince(started)
            if elapsed > 1.5 { Log.info(.playback, "HLS warm-up: segment at \(Int(start)) s ready after \(String(format: "%.1f", elapsed)) s") }
        } catch {
            Log.notice(.playback, "HLS warm-up gave up after \(String(format: "%.1f", Date().timeIntervalSince(started))) s: \(error.localizedDescription)")
        }
    }

    /// The URI of the segment containing `time` (sum of `#EXTINF` durations); the last segment past the end.
    static func segmentURI(in playlist: String, at time: TimeInterval) -> String? {
        var elapsed: TimeInterval = 0
        var duration: TimeInterval?
        var last: String?
        for line in playlist.split(whereSeparator: \.isNewline).map({ $0.trimmingCharacters(in: .whitespaces) }) where !line.isEmpty {
            if line.hasPrefix("#EXTINF:") {
                duration = TimeInterval(line.dropFirst(8).prefix { $0 != "," }.trimmingCharacters(in: .whitespaces))
            } else if !line.hasPrefix("#") {
                let length = duration ?? 0
                if time < elapsed + length { return line }
                elapsed += length
                duration = nil
                last = line
            }
        }
        return last
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
