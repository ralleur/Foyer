import Foundation
import JellyfinKit
import FoyerFoundation

extension BaseItem {
    var yearText: String? { productionYear.map(String.init) }

    /// "2 h 16 min" localized.
    var runtimeText: String? {
        guard let runtime, runtime > 0 else { return nil }
        return DurationFormatting.hoursMinutes(runtime)
    }

    var ratingText: String? {
        guard let communityRating, communityRating > 0 else { return nil }
        return String(format: "%.1f", communityRating)
    }

    /// Meta line under titles: "2024 · 2 h 46 min · FSK 12".
    var metaLine: String {
        var parts: [String] = []
        if let yearText { parts.append(yearText) }
        if let runtimeText { parts.append(runtimeText) }
        if let officialRating, !officialRating.isEmpty { parts.append(officialRating) }
        return parts.joined(separator: " · ")
    }

    /// Series status line: "2019 – 2023 · 4 seasons".
    var seriesMetaLine: String {
        var parts: [String] = []
        if let start = productionYear {
            if status?.lowercased() == "ended", let end = endDate {
                let endYear = Calendar.current.component(.year, from: end)
                parts.append(endYear == start ? "\(start)" : "\(start) – \(endYear)")
            } else if status?.lowercased() == "continuing" {
                parts.append("\(start) –")
            } else {
                parts.append("\(start)")
            }
        }
        if let officialRating, !officialRating.isEmpty { parts.append(officialRating) }
        return parts.joined(separator: " · ")
    }

    /// Series name + episode label for episode cards.
    var episodeSubtitle: String {
        [seriesName, episodeLabel].compactMap { $0 }.joined(separator: " · ")
    }

    /// The title shown on cards: episodes show their series name.
    var cardTitle: String {
        if isEpisode, let seriesName { return seriesName }
        return displayTitle
    }

    var cardSubtitle: String? {
        if isEpisode {
            return [episodeLabel, name].compactMap { $0 }.joined(separator: " · ")
        }
        if isSeason {
            return seriesName
        }
        return yearText
    }

    var unplayedCountBadge: Int? {
        guard isSeries || isSeason || isCollection, let count = userData?.unplayedItemCount, count > 0 else { return nil }
        return count
    }

    var directors: [Person] { people?.filter { $0.type?.lowercased() == "director" } ?? [] }
    var writers: [Person] { people?.filter { $0.type?.lowercased() == "writer" } ?? [] }
    var actors: [Person] { people?.filter { $0.type?.lowercased() == "actor" } ?? [] }

    /// Media badges like ["4K", "HDR10", "Atmos"] from the default media source.
    var technicalBadges: [String] {
        guard let source = defaultMediaSource ?? mediaStreams.map({ MediaSource(id: id, container: container, mediaStreams: $0) }) else { return [] }
        var badges: [String] = []
        if let video = source.videoStream {
            if let res = video.resolutionLabel, res == "4K" { badges.append("4K") }
            let range = video.effectiveVideoRange
            if range.isDolbyVision { badges.append("Dolby Vision") } else if range.isHDR { badges.append(range == .hlg ? "HLG" : "HDR") }
        }
        if source.audioStreams.contains(where: { $0.isObjectAudio }) { badges.append("Atmos") }
        return badges
    }
}

enum DurationFormatting {
    nonisolated(unsafe) private static let formatter: DateComponentsFormatter = {
        let f = DateComponentsFormatter()
        f.allowedUnits = [.hour, .minute]
        f.unitsStyle = .abbreviated
        f.zeroFormattingBehavior = .dropAll
        return f
    }()

    static func hoursMinutes(_ interval: TimeInterval) -> String {
        formatter.string(from: max(60, interval.rounded())) ?? interval.clockString
    }

    nonisolated(unsafe) private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.timeStyle = .short
        f.dateStyle = .none
        return f
    }()

    static func clockTime(_ date: Date) -> String {
        timeFormatter.string(from: date)
    }
}
