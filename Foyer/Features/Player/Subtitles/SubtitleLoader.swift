import Foundation
import FoyerFoundation
import PlaybackDecision

/// Downloads and parses external text subtitles once per URL.
actor SubtitleLoader {
    static let shared = SubtitleLoader()

    private var cache: [URL: SubtitleTimeline] = [:]
    private var inflight: [URL: Task<SubtitleTimeline, any Error>] = [:]
    private let session: URLSession = {
        let config = URLSessionConfiguration.default
        // Jellyfin extracts embedded subtitles from the file on first request; a 4K remux can take a minute.
        config.timeoutIntervalForRequest = 120
        config.requestCachePolicy = .returnCacheDataElseLoad
        return URLSession(configuration: config)
    }()

    func timeline(for url: URL, format: SubtitleTextFormat?) async throws -> SubtitleTimeline {
        if let cached = cache[url] { return cached }
        if let task = inflight[url] { return try await task.value }
        let task = Task<SubtitleTimeline, any Error> {
            let (data, response) = try await session.data(from: url)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                throw FoyerError(.subtitlesUnavailable, detail: "HTTP \(http.statusCode) for subtitle")
            }
            let text = Self.decode(data)
            let cues = SubtitleParser.parse(text, format: format)
            return SubtitleTimeline(cues: cues)
        }
        inflight[url] = task
        defer { inflight[url] = nil }
        let timeline = try await task.value
        cache[url] = timeline
        if cache.count > 40 { cache.removeValue(forKey: cache.keys.first!) }
        return timeline
    }

    func clear() { cache.removeAll() }

    /// UTF-8 with BOM handling, falling back to Windows-1252/Latin-1 for old SRT files.
    nonisolated static func decode(_ data: Data) -> String {
        let text: String
        if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]) {
            text = String(data: data, encoding: .utf16) ?? ""
        } else if let utf8 = String(data: data, encoding: .utf8) {
            text = utf8
        } else if let cp1252 = String(data: data, encoding: .windowsCP1252) {
            text = cp1252
        } else {
            text = String(data: data, encoding: .isoLatin1) ?? String(decoding: data, as: UTF8.self)
        }
        // A byte order mark must never reach the parser (it would corrupt the first cue index).
        return text.hasPrefix("\u{FEFF}") ? String(text.dropFirst()) : text
    }
}
