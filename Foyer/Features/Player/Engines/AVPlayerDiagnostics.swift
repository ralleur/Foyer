import AVFoundation
import CoreMedia

/// Turns AVFoundation's terse failures into log lines with the underlying error chain, the tracks
/// and format descriptions AVPlayer saw, and its access/error logs.
enum AVPlayerDiagnostics {
    static func describe(_ error: NSError?) -> String {
        guard let error else { return "no error" }
        var parts: [String] = []
        var current: NSError? = error
        var depth = 0
        while let e = current, depth < 5 {
            parts.append("\(e.domain) \(e.code) (\(e.localizedDescription))")
            if let reason = e.userInfo[NSLocalizedFailureReasonErrorKey] as? String { parts.append("reason: \(reason)") }
            current = e.userInfo[NSUnderlyingErrorKey] as? NSError
            depth += 1
        }
        return parts.joined(separator: " ← ")
    }

    static func describe(_ item: AVPlayerItem) -> String {
        var parts: [String] = []
        if let error = item.error as NSError? { parts.append("item error: \(describe(error))") }
        let tracks = item.tracks.compactMap { track -> String? in
            guard let asset = track.assetTrack else { return nil }
            let descriptions = asset.formatDescriptions as? [CMFormatDescription] ?? []
            let formats = descriptions.map { description -> String in
                let subtype = fourCC(CMFormatDescriptionGetMediaSubType(description))
                guard CMFormatDescriptionGetMediaType(description) == kCMMediaType_Video else { return subtype }
                let dimensions = CMVideoFormatDescriptionGetDimensions(description)
                let extensions = (CMFormatDescriptionGetExtensions(description) as? [String: Any]) ?? [:]
                return "\(subtype) \(dimensions.width)x\(dimensions.height) [\(extensions.keys.sorted().joined(separator: ","))]"
            }
            return "\(asset.mediaType.rawValue): \(formats.joined(separator: "|")) enabled=\(track.isEnabled)"
        }
        parts.append("tracks: \(tracks.isEmpty ? "none" : tracks.joined(separator: "; "))")
        parts.append("presentation \(Int(item.presentationSize.width))x\(Int(item.presentationSize.height))")
        if let event = item.accessLog()?.events.last {
            let uri = event.uri?.split(separator: "?").first.map(String.init) ?? "-"
            parts.append("access: \(event.playbackType ?? "-") indicated \(Int(event.indicatedBitrate / 1000)) kbit/s requests \(event.numberOfMediaRequests) stalls \(event.numberOfStalls) dropped \(event.numberOfDroppedVideoFrames) uri \(uri)")
        }
        let errors = errorLog(item)
        if !errors.isEmpty { parts.append("error log: \(errors)") }
        return parts.joined(separator: "; ")
    }

    static func errorLog(_ item: AVPlayerItem) -> String {
        (item.errorLog()?.events ?? []).suffix(3).map { event in
            "\(event.errorDomain) \(event.errorStatusCode) \(event.errorComment ?? "") @\(event.uri?.split(separator: "?").first.map(String.init) ?? "-")"
        }.joined(separator: " | ")
    }

    private static func fourCC(_ code: FourCharCode) -> String {
        let bytes = [UInt8(code >> 24 & 0xff), UInt8(code >> 16 & 0xff), UInt8(code >> 8 & 0xff), UInt8(code & 0xff)]
        return String(bytes: bytes, encoding: .macOSRoman) ?? String(code)
    }
}
