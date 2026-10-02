import Foundation

/// A single timed text cue.
public struct SubtitleCue: Sendable, Hashable, Identifiable {
    public var id: Int
    public var start: TimeInterval
    public var end: TimeInterval
    public var text: String
    /// True when the author positioned the cue at the top of the frame.
    public var isTop: Bool

    public init(id: Int, start: TimeInterval, end: TimeInterval, text: String, isTop: Bool = false) {
        self.id = id
        self.start = start
        self.end = end
        self.text = text
        self.isTop = isTop
    }
}

public enum SubtitleTextFormat: Sendable {
    case srt, webvtt, ass

    /// Detects the format from content (falls back to the hint).
    public static func detect(_ text: String, hint: SubtitleTextFormat?) -> SubtitleTextFormat {
        let head = text.prefix(4000)
        if head.hasPrefix("WEBVTT") || head.contains("\nWEBVTT") { return .webvtt }
        if head.contains("[Script Info]") || head.contains("[Events]") || head.contains("Dialogue:") { return .ass }
        if let hint { return hint }
        return .srt
    }
}

/// Parsers for text subtitle formats used by the native engine's overlay.
/// Styling is intentionally reduced to plain text with line breaks; italics
/// markers are kept as `<i>` so the renderer can honour them.
public enum SubtitleParser {
    public static func parse(_ raw: String, format hint: SubtitleTextFormat? = nil) -> [SubtitleCue] {
        var text = raw
        if text.hasPrefix("\u{FEFF}") { text.removeFirst() }
        text = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        switch SubtitleTextFormat.detect(text, hint: hint) {
        case .srt: return parseSRT(text)
        case .webvtt: return parseVTT(text)
        case .ass: return parseASS(text)
        }
    }

    // MARK: SRT

    static func parseSRT(_ text: String) -> [SubtitleCue] {
        var cues: [SubtitleCue] = []
        let blocks = text.components(separatedBy: "\n\n")
        for block in blocks {
            let lines = block.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            guard let timingLineIndex = lines.firstIndex(where: { $0.contains("-->") }) else { continue }
            let timing = lines[timingLineIndex]
            guard let (start, end) = parseTimingLine(timing) else { continue }
            let body = lines[(timingLineIndex + 1)...].joined(separator: "\n")
            let (clean, top) = cleanText(body)
            guard !clean.isEmpty else { continue }
            cues.append(SubtitleCue(id: cues.count, start: start, end: end, text: clean, isTop: top))
        }
        return cues.sorted { $0.start < $1.start }
    }

    // MARK: WebVTT

    static func parseVTT(_ text: String) -> [SubtitleCue] {
        var cues: [SubtitleCue] = []
        let blocks = text.components(separatedBy: "\n\n")
        for block in blocks {
            let trimmed = block.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty || trimmed.hasPrefix("WEBVTT") || trimmed.hasPrefix("NOTE") || trimmed.hasPrefix("STYLE") || trimmed.hasPrefix("REGION") {
                continue
            }
            let lines = trimmed.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            guard let timingLineIndex = lines.firstIndex(where: { $0.contains("-->") }) else { continue }
            let timing = lines[timingLineIndex]
            guard let (start, end) = parseTimingLine(timing) else { continue }
            let settings = timing.components(separatedBy: "-->").last ?? ""
            var top = false
            if let lineSetting = settings.split(separator: " ").first(where: { $0.hasPrefix("line:") }) {
                let value = lineSetting.dropFirst(5)
                if let pct = Double(value.replacingOccurrences(of: "%", with: "")), pct >= 0, pct < 50, value.hasSuffix("%") { top = true }
                else if let n = Int(value), n >= 0, n < 5 { top = true }
            }
            let body = lines[(timingLineIndex + 1)...].joined(separator: "\n")
            let (clean, tagTop) = cleanText(body)
            guard !clean.isEmpty else { continue }
            cues.append(SubtitleCue(id: cues.count, start: start, end: end, text: clean, isTop: top || tagTop))
        }
        return cues.sorted { $0.start < $1.start }
    }

    // MARK: ASS / SSA

    static func parseASS(_ text: String) -> [SubtitleCue] {
        var cues: [SubtitleCue] = []
        var inEvents = false
        var format: [String] = []
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") {
                inEvents = line.lowercased().hasPrefix("[events]")
                continue
            }
            guard inEvents else { continue }
            if line.lowercased().hasPrefix("format:") {
                format = line.dropFirst(7).split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
                continue
            }
            guard line.lowercased().hasPrefix("dialogue:") else { continue }
            let payload = line.dropFirst(9)
            let fields = payload.split(separator: ",", maxSplits: max(format.count - 1, 9), omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
            let columns = format.isEmpty ? ["layer", "start", "end", "style", "name", "marginl", "marginr", "marginv", "effect", "text"] : format
            guard let startIdx = columns.firstIndex(of: "start"), let endIdx = columns.firstIndex(of: "end"),
                  let textIdx = columns.firstIndex(of: "text"), fields.count > max(startIdx, endIdx), fields.count > textIdx else { continue }
            guard let start = parseASSTime(fields[startIdx]), let end = parseASSTime(fields[endIdx]) else { continue }
            guard let (clean, top) = cleanASSText(fields[textIdx...].joined(separator: ",")) else { continue }
            cues.append(SubtitleCue(id: cues.count, start: start, end: end, text: clean, isTop: top))
        }
        return cues.sorted { $0.start < $1.start }
    }

    /// One event as FFmpeg's subtitle decoders hand it out for embedded text tracks (SubRip and WebVTT are
    /// converted to ASS too): `ReadOrder,Layer,Style,Name,MarginL,MarginR,MarginV,Effect,Text`.
    public static func cue(fromDecoderEvent event: String, id: Int, start: TimeInterval, end: TimeInterval) -> SubtitleCue? {
        let fields = event.split(separator: ",", maxSplits: 8, omittingEmptySubsequences: false)
        let body = fields.count == 9 ? String(fields[8]) : event // plain text from decoders that do not emit ASS
        guard let (clean, top) = cleanASSText(body) else { return nil }
        return SubtitleCue(id: id, start: start, end: end, text: clean, isTop: top)
    }

    /// ASS dialogue text → display text; nil for drawings and empty events.
    static func cleanASSText(_ raw: String) -> (String, Bool)? {
        var body = raw
        // Skip vector drawings.
        if body.contains("\\p1") || body.contains("\\p2") || body.contains("\\p4") { return nil }
        var top = body.range(of: #"\\an?[789]"#, options: .regularExpression) != nil
        if body.range(of: #"\\a[5-7]\b"#, options: .regularExpression) != nil { top = true }
        body = body.replacingOccurrences(of: #"\{[^}]*\}"#, with: "", options: .regularExpression)
        body = body.replacingOccurrences(of: "\\N", with: "\n").replacingOccurrences(of: "\\n", with: "\n").replacingOccurrences(of: "\\h", with: " ")
        let (clean, tagTop) = cleanText(body)
        return clean.isEmpty ? nil : (clean, top || tagTop)
    }

    // MARK: Helpers

    static func parseTimingLine(_ line: String) -> (TimeInterval, TimeInterval)? {
        let parts = line.components(separatedBy: "-->")
        guard parts.count == 2 else { return nil }
        let startString = parts[0].trimmingCharacters(in: .whitespaces)
        let endString = parts[1].trimmingCharacters(in: .whitespaces).split(separator: " ").first.map(String.init) ?? ""
        guard let start = parseTimestamp(startString), let end = parseTimestamp(endString), end >= start else { return nil }
        return (start, end)
    }

    /// Accepts "hh:mm:ss,mmm", "hh:mm:ss.mmm", "mm:ss.mmm".
    static func parseTimestamp(_ raw: String) -> TimeInterval? {
        let normalized = raw.replacingOccurrences(of: ",", with: ".")
        let pieces = normalized.split(separator: ":").map(String.init)
        guard pieces.count == 2 || pieces.count == 3 else { return nil }
        guard let seconds = Double(pieces.last ?? "") else { return nil }
        var total = seconds
        if pieces.count == 3 {
            guard let h = Double(pieces[0]), let m = Double(pieces[1]) else { return nil }
            total += h * 3600 + m * 60
        } else {
            guard let m = Double(pieces[0]) else { return nil }
            total += m * 60
        }
        return total
    }

    /// ASS uses "h:mm:ss.cc" (centiseconds).
    static func parseASSTime(_ raw: String) -> TimeInterval? {
        parseTimestamp(raw)
    }

    /// Removes HTML-ish tags except italics, and SRT positioning tags like {\an8}.
    static func cleanText(_ body: String) -> (String, Bool) {
        var text = body
        var top = false
        if text.range(of: #"\{\\an[789]\}"#, options: .regularExpression) != nil { top = true }
        text = text.replacingOccurrences(of: #"\{\\[^}]*\}"#, with: "", options: .regularExpression)
        // Keep italic markers, normalise them.
        text = text.replacingOccurrences(of: #"<\s*i\s*>"#, with: "<i>", options: [.regularExpression, .caseInsensitive])
        text = text.replacingOccurrences(of: #"<\s*/\s*i\s*>"#, with: "</i>", options: [.regularExpression, .caseInsensitive])
        // Drop everything else (<b>, <font ...>, <c.class>, <v Speaker>, ruby...).
        text = text.replacingOccurrences(of: #"<(?!/?i>)[^>]*>"#, with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        var collapsed: [String] = []
        for line in lines where !(line.isEmpty && (collapsed.last?.isEmpty ?? true)) {
            collapsed.append(line)
        }
        while collapsed.last?.isEmpty == true { collapsed.removeLast() }
        return (collapsed.joined(separator: "\n"), top)
    }
}

/// Fast lookup of the cues visible at a given time. Cues may overlap.
public struct SubtitleTimeline: Sendable, Hashable {
    public let cues: [SubtitleCue]
    private let maxDuration: TimeInterval

    public init(cues: [SubtitleCue]) {
        self.cues = cues.sorted { $0.start < $1.start }
        self.maxDuration = cues.map { $0.end - $0.start }.max() ?? 0
    }

    public var isEmpty: Bool { cues.isEmpty }

    /// Cues active at `time` (already offset by any user delay by the caller).
    public func activeCues(at time: TimeInterval) -> [SubtitleCue] {
        guard !cues.isEmpty else { return [] }
        // Binary search for the last cue starting at or before `time`.
        var low = 0
        var high = cues.count - 1
        var lastIndex = -1
        while low <= high {
            let mid = (low + high) / 2
            if cues[mid].start <= time {
                lastIndex = mid
                low = mid + 1
            } else {
                high = mid - 1
            }
        }
        guard lastIndex >= 0 else { return [] }
        var result: [SubtitleCue] = []
        var i = lastIndex
        let floor = time - maxDuration
        while i >= 0, cues[i].start >= floor {
            if cues[i].end > time { result.append(cues[i]) }
            i -= 1
        }
        return result.reversed()
    }

    /// The next cue start after `time`, so a renderer can schedule its next refresh precisely.
    public func nextChange(after time: TimeInterval) -> TimeInterval? {
        var next: TimeInterval?
        for cue in activeCues(at: time) {
            next = min(next ?? cue.end, cue.end)
        }
        if let idx = cues.firstIndex(where: { $0.start > time }) {
            next = min(next ?? cues[idx].start, cues[idx].start)
        }
        return next
    }
}
