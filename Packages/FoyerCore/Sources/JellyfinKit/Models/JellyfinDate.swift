import Foundation
import FoyerFoundation

/// Jellyfin emits ISO 8601 with up to seven fractional digits ("2024-05-01T12:34:56.1234567Z").
/// Foundation's ISO8601DateFormatter only accepts three, so we normalise first.
public enum JellyfinDate {
    private static let withFraction = UncheckedSendable<ISO8601DateFormatter>({
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }())

    private static let plain = UncheckedSendable<ISO8601DateFormatter>({
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }())

    private static let noZone = UncheckedSendable<DateFormatter>({
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(secondsFromGMT: 0)
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        return f
    }())

    public static func parse(_ raw: String) -> Date? {
        var s = raw.trimmingCharacters(in: .whitespaces)
        guard !s.isEmpty else { return nil }
        // Trim fractional seconds to three digits.
        if let dot = s.firstIndex(of: ".") {
            var end = s.index(after: dot)
            while end < s.endIndex, s[end].isNumber { end = s.index(after: end) }
            let fraction = s[s.index(after: dot)..<end]
            let trimmed = String(fraction.prefix(3)).padding(toLength: 3, withPad: "0", startingAt: 0)
            s.replaceSubrange(dot..<end, with: "." + trimmed)
        }
        // Server may omit the zone; treat as UTC.
        let hasZone = s.hasSuffix("Z") || s.range(of: #"[+-]\d\d:?\d\d$"#, options: .regularExpression) != nil
        if !hasZone {
            if let d = noZone.value.date(from: String(s.prefix(19))) { return d }
            s += "Z"
        }
        if s.contains(".") {
            if let d = withFraction.value.date(from: s) { return d }
        }
        if let d = plain.value.date(from: s) { return d }
        // Last resort: drop fraction entirely.
        if let dot = s.firstIndex(of: "."), let zoneStart = s[dot...].firstIndex(where: { $0 == "Z" || $0 == "+" || $0 == "-" }) {
            let stripped = String(s[..<dot]) + String(s[zoneStart...])
            return plain.value.date(from: stripped)
        }
        return nil
    }

    public static func string(_ date: Date) -> String {
        withFraction.value.string(from: date)
    }

    public static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let raw = try container.decode(String.self)
            if let date = parse(raw) { return date }
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unparseable date: \(raw)")
        }
        return decoder
    }

    public static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(string(date))
        }
        return encoder
    }
}
