import Foundation
import FoyerFoundation

public extension JellyfinClient {
    func playbackInfo(itemId: String, request: PlaybackInfoRequest) async throws -> PlaybackInfoResponse {
        var body = request
        body.userId = body.userId ?? userId
        let endpoint = try Endpoint.post("/Items/\(itemId)/PlaybackInfo", query: [URLQueryItem(name: "userId", value: try requireUserId())], json: body)
        return try await send(endpoint)
    }

    func reportPlaybackStart(_ report: PlaybackStateReport) async throws {
        try await send(try Endpoint.post("/Sessions/Playing", json: report))
    }

    func reportPlaybackProgress(_ report: PlaybackStateReport) async throws {
        try await send(try Endpoint.post("/Sessions/Playing/Progress", json: report))
    }

    func reportPlaybackStopped(_ report: PlaybackStopReport) async throws {
        try await send(try Endpoint.post("/Sessions/Playing/Stopped", json: report))
    }

    /// Tells the server to release transcoding resources for a play session.
    func stopTranscoding(playSessionId: String) async throws {
        try await send(.delete("/Videos/ActiveEncodings", query: [
            URLQueryItem(name: "deviceId", value: identity.deviceId),
            URLQueryItem(name: "playSessionId", value: playSessionId),
        ]))
    }

    // MARK: Segments (intro / credits)

    /// Media segments from Jellyfin 10.10+, falling back to the Intro Skipper plugin
    /// endpoints on older servers. Returns an empty list when nothing is known.
    func mediaSegments(itemId: String) async throws -> [MediaSegment] {
        var segments: [MediaSegment] = []
        do {
            let query = [MediaSegmentType.intro, .outro, .recap, .preview, .commercial].map {
                URLQueryItem(name: "includeSegmentTypes", value: $0.rawValue)
            }
            let result: QueryResult<MediaSegment> = try await send(.get("/MediaSegments/\(itemId)", query: query))
            let known: Set<MediaSegmentType> = [.intro, .outro, .recap, .preview, .commercial]
            segments = result.items.filter { $0.endTicks > $0.startTicks && known.contains($0.type) }
        } catch let error as FoyerError where error.kind == .notFound {
            // Endpoint absent on < 10.10; try the plugin below.
        }
        if segments.isEmpty {
            segments = try await introSkipperSegments(itemId: itemId)
        }
        return segments.sorted { $0.startTicks < $1.startTicks }
    }

    func introSkipperSegments(itemId: String) async throws -> [MediaSegment] {
        do {
            let result: IntroSkipperSegments = try await send(.get("/Episode/\(itemId)/IntroSkipperSegments"))
            let segments = result.segments
            if !segments.isEmpty { return segments }
        } catch let error as FoyerError where error.kind == .notFound || error.kind == .accessDenied {
            // fall through to legacy endpoint
        } catch let error as FoyerError {
            if case .serverError = error.kind { /* plugin absent or misbehaving */ } else { throw error }
        }
        do {
            let intro: IntroSkipperTimestamps = try await send(.get("/Episode/\(itemId)/IntroTimestamps/v1"))
            return [intro.asSegment(type: .intro)].compactMap { $0 }
        } catch let error as FoyerError where error.kind == .notFound || error.kind == .accessDenied {
            return []
        } catch let error as FoyerError {
            if case .serverError = error.kind { return [] }
            throw error
        }
    }

    // MARK: Media URLs (synchronous; used by players and image loaders)

    /// Direct play URL: the file is served as-is.
    func directStreamURL(itemId: String, mediaSourceId: String, playSessionId: String?, eTag: String?, container: String?) -> URL? {
        var query = [
            URLQueryItem(name: "static", value: "true"),
            URLQueryItem(name: "mediaSourceId", value: mediaSourceId),
            URLQueryItem(name: "deviceId", value: identity.deviceId),
        ]
        if let playSessionId { query.append(URLQueryItem(name: "playSessionId", value: playSessionId)) }
        if let eTag { query.append(URLQueryItem(name: "Tag", value: eTag)) }
        // Using the container as extension helps players sniff the format quickly.
        let ext = container.flatMap { $0.split(separator: ",").first }.map { ".\($0)" } ?? ""
        return mediaURL(for: "/Videos/\(itemId)/stream\(ext)", query: query)
    }

    /// URL for a server-provided transcoding/remux path (`MediaSource.transcodingUrl`).
    func transcodingURL(path: String) -> URL? {
        mediaURL(for: path)
    }

    /// External subtitle stream (server extracts embedded text subtitles on demand).
    func subtitleURL(itemId: String, mediaSourceId: String, streamIndex: Int, format: String, deliveryUrl: String? = nil) -> URL? {
        if let deliveryUrl, !deliveryUrl.isEmpty {
            return mediaURL(for: deliveryUrl)
        }
        return mediaURL(for: "/Videos/\(itemId)/\(mediaSourceId)/Subtitles/\(streamIndex)/0/Stream.\(format)")
    }

    /// Embedded font attachment (for ASS rendering).
    func attachmentURL(itemId: String, mediaSourceId: String, attachmentIndex: Int) -> URL? {
        mediaURL(for: "/Videos/\(itemId)/\(mediaSourceId)/Attachments/\(attachmentIndex)")
    }

    func trickplayTileURL(itemId: String, width: Int, tileIndex: Int, mediaSourceId: String?) -> URL? {
        var query: [URLQueryItem] = []
        if let mediaSourceId { query.append(URLQueryItem(name: "mediaSourceId", value: mediaSourceId)) }
        return mediaURL(for: "/Videos/\(itemId)/Trickplay/\(width)/\(tileIndex).jpg", query: query)
    }

    func imageURL(itemId: String, type: ImageType, tag: String?, maxWidth: Int? = nil, maxHeight: Int? = nil, index: Int? = nil, quality: Int = 90) -> URL? {
        var query: [URLQueryItem] = [URLQueryItem(name: "quality", value: String(quality))]
        if let tag { query.append(URLQueryItem(name: "tag", value: tag)) }
        if let maxWidth { query.append(URLQueryItem(name: "maxWidth", value: String(maxWidth))) }
        if let maxHeight { query.append(URLQueryItem(name: "maxHeight", value: String(maxHeight))) }
        let suffix = index.map { "/\($0)" } ?? ""
        return url(for: "/Items/\(itemId)/Images/\(type.rawValue)\(suffix)", query: query)
    }

    func userImageURL(userId: String, tag: String?, maxWidth: Int = 200) -> URL? {
        var query = [URLQueryItem(name: "maxWidth", value: String(maxWidth))]
        if let tag { query.append(URLQueryItem(name: "tag", value: tag)) }
        return url(for: "/UserImage", query: [URLQueryItem(name: "userId", value: userId)] + query)
    }
}
