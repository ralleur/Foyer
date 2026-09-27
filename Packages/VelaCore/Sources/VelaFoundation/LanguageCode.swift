import Foundation

/// Normalises language tags found in media files (ISO 639-1, 639-2/B, 639-2/T, BCP-47)
/// to a canonical two-letter code so "ger", "deu", "de-DE" and "de" all compare equal.
public enum LanguageCode {
    private static let threeToTwo: [String: String] = [
        "ger": "de", "deu": "de",
        "eng": "en",
        "fre": "fr", "fra": "fr",
        "spa": "es",
        "ita": "it",
        "por": "pt",
        "dut": "nl", "nld": "nl",
        "swe": "sv",
        "nor": "no", "nob": "nb", "nno": "nn",
        "dan": "da",
        "fin": "fi",
        "pol": "pl",
        "cze": "cs", "ces": "cs",
        "slo": "sk", "slk": "sk",
        "hun": "hu",
        "rum": "ro", "ron": "ro",
        "rus": "ru",
        "ukr": "uk",
        "bul": "bg",
        "gre": "el", "ell": "el",
        "tur": "tr",
        "ara": "ar",
        "heb": "he",
        "hin": "hi",
        "jpn": "ja",
        "kor": "ko",
        "chi": "zh", "zho": "zh",
        "tha": "th",
        "vie": "vi",
        "ind": "id",
        "may": "ms", "msa": "ms",
        "per": "fa", "fas": "fa",
        "cat": "ca",
        "baq": "eu", "eus": "eu",
        "glg": "gl",
        "hrv": "hr",
        "srp": "sr",
        "slv": "sl",
        "lit": "lt",
        "lav": "lv",
        "est": "et",
        "ice": "is", "isl": "is",
        "gle": "ga",
        "wel": "cy", "cym": "cy",
        "afr": "af",
        "swa": "sw",
        "tam": "ta",
        "tel": "te",
        "ben": "bn",
        "urd": "ur",
        "fil": "tl", "tgl": "tl",
        "lat": "la",
    ]

    /// Codes that mean "undetermined" and must never match a preference.
    private static let undetermined: Set<String> = ["und", "mis", "mul", "zxx", "", "unknown", "none"]

    /// Returns the canonical two-letter code, or nil for undetermined/unknown tags.
    public static func normalize(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let lower = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if undetermined.contains(lower) { return nil }
        let base = lower.split(whereSeparator: { $0 == "-" || $0 == "_" }).first.map(String.init) ?? lower
        if base.count == 2 { return base }
        if let mapped = threeToTwo[base] { return mapped }
        if base.count == 3 {
            // Unknown 3-letter code: keep it so equal tags still match each other.
            return base
        }
        return base.isEmpty ? nil : base
    }

    public static func matches(_ a: String?, _ b: String?) -> Bool {
        guard let na = normalize(a), let nb = normalize(b) else { return false }
        return na == nb
    }

    /// Human readable name using the current locale (falls back to the code).
    public static func displayName(_ raw: String?, locale: Locale = .current) -> String? {
        guard let code = normalize(raw) else { return nil }
        if let name = locale.localizedString(forLanguageCode: code) {
            return name.prefix(1).uppercased() + name.dropFirst()
        }
        return code.uppercased()
    }
}
