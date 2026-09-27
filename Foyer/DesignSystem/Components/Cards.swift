import SwiftUI
import JellyfinKit

/// Portrait poster card with title below; focus lifts the artwork and highlights the text.
struct PosterCard: View {
    let item: BaseItem
    let imageURL: URL?
    var showProgress: Bool = true
    var onFocus: ((BaseItem) -> Void)? = nil
    let action: () -> Void

    @FocusState private var isFocused: Bool
    @Environment(AppEnvironment.self) private var environment

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            Button(action: action) {
                ZStack(alignment: .bottom) {
                    RemoteImage(url: imageURL, targetSize: CardSize.poster)
                        .frame(width: CardSize.poster.width, height: CardSize.poster.height)
                    if showProgress, let percent = item.playedPercentage {
                        ProgressBar(fraction: percent / 100)
                            .padding(.horizontal, Spacing.s)
                            .padding(.bottom, Spacing.s)
                    }
                    badges
                }
                .frame(width: CardSize.poster.width, height: CardSize.poster.height)
                .clipShape(RoundedRectangle(cornerRadius: Radius.poster, style: .continuous))
                .overlay(alignment: .topTrailing) { watchedIndicator }
            }
            .buttonStyle(CardButtonStyleFoyer())
            .focused($isFocused)
            .accessibilityLabel(accessibilityText)

            VStack(alignment: .leading, spacing: 4) {
                Text(item.cardTitle)
                    .font(Typography.cardTitle)
                    .foregroundStyle(isFocused ? Color.foyerPrimaryText : Color.foyerSecondaryText)
                    .lineLimit(1)
                if let subtitle = item.cardSubtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(Typography.cardSubtitle)
                        .foregroundStyle(Color.foyerTertiaryText)
                        .lineLimit(1)
                }
            }
            .frame(width: CardSize.poster.width, alignment: .leading)
            .padding(.leading, 4)
        }
        .onChange(of: isFocused) { _, focused in
            if focused { onFocus?(item) }
        }
    }

    @ViewBuilder private var badges: some View {
        if environment.preferences.showTechnicalBadges, !item.technicalBadges.isEmpty, !showProgressActive {
            HStack(spacing: 4) {
                ForEach(item.technicalBadges.prefix(2), id: \.self) { MetaBadge(text: $0) }
            }
            .padding(Spacing.xs)
            .frame(maxWidth: .infinity, alignment: .trailing)
            .opacity(isFocused ? 1 : 0)
        }
    }

    private var showProgressActive: Bool { showProgress && item.playedPercentage != nil }

    @ViewBuilder private var watchedIndicator: some View {
        if let count = item.unplayedCountBadge {
            Text("\(count)")
                .font(Typography.caption)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(Capsule().fill(Color.foyerAccent))
                .foregroundStyle(.black)
                .padding(Spacing.xs)
        } else if item.isPlayed, item.isPlayable {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 26))
                .foregroundStyle(.white, Color.foyerAccent)
                .padding(Spacing.xs)
        }
    }

    private var accessibilityText: String {
        var parts = [item.cardTitle]
        if let subtitle = item.cardSubtitle { parts.append(subtitle) }
        if let percent = item.playedPercentage { parts.append("\(Int(percent)) %") }
        if item.isPlayed { parts.append(L10n.watched) }
        return parts.joined(separator: ", ")
    }
}

/// 16:9 card for episodes and Continue Watching.
struct LandscapeCard: View {
    let item: BaseItem
    let imageURL: URL?
    var size: CGSize = CardSize.landscape
    var showProgress: Bool = true
    var titleOverride: String? = nil
    var subtitleOverride: String? = nil
    var onFocus: ((BaseItem) -> Void)? = nil
    let action: () -> Void

    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            Button(action: action) {
                ZStack(alignment: .bottom) {
                    RemoteImage(url: imageURL, targetSize: size, systemImage: "play.rectangle")
                        .frame(width: size.width, height: size.height)
                    LinearGradient(colors: [.clear, .black.opacity(0.55)], startPoint: .center, endPoint: .bottom)
                    if showProgress, let percent = item.playedPercentage {
                        ProgressBar(fraction: percent / 100)
                            .padding(.horizontal, Spacing.s)
                            .padding(.bottom, Spacing.s)
                    }
                }
                .frame(width: size.width, height: size.height)
                .clipShape(RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
                .overlay(alignment: .topTrailing) {
                    if item.isPlayed, item.isPlayable {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 26))
                            .foregroundStyle(.white, Color.foyerAccent)
                            .padding(Spacing.xs)
                    }
                }
                .overlay(alignment: .bottomTrailing) {
                    if let runtime = remainingLabel {
                        Text(runtime)
                            .font(Typography.caption)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Capsule().fill(.black.opacity(0.6)))
                            .padding(Spacing.s)
                            .padding(.bottom, showProgress && item.playedPercentage != nil ? 14 : 0)
                    }
                }
            }
            .buttonStyle(CardButtonStyleFoyer())
            .focused($isFocused)
            .accessibilityLabel(accessibilityText)

            VStack(alignment: .leading, spacing: 4) {
                Text(titleOverride ?? item.cardTitle)
                    .font(Typography.cardTitle)
                    .foregroundStyle(isFocused ? Color.foyerPrimaryText : Color.foyerSecondaryText)
                    .lineLimit(1)
                if let subtitle = subtitleOverride ?? item.cardSubtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(Typography.cardSubtitle)
                        .foregroundStyle(Color.foyerTertiaryText)
                        .lineLimit(1)
                }
            }
            .frame(width: size.width, alignment: .leading)
            .padding(.leading, 4)
        }
        .onChange(of: isFocused) { _, focused in
            if focused { onFocus?(item) }
        }
    }

    private var remainingLabel: String? {
        guard let runtime = item.runtime, runtime > 0 else { return nil }
        if let position = item.resumePosition {
            let remaining = max(0, runtime - position)
            return "\(max(1, remaining.wholeMinutes)) min " + L10n.remaining
        }
        return "\(runtime.wholeMinutes) min"
    }

    private var accessibilityText: String {
        var parts = [titleOverride ?? item.cardTitle]
        if let subtitle = subtitleOverride ?? item.cardSubtitle { parts.append(subtitle) }
        if let percent = item.playedPercentage { parts.append("\(Int(percent)) %") }
        return parts.joined(separator: ", ")
    }
}

/// Library / collection tile.
struct LibraryTile: View {
    let title: String
    let imageURL: URL?
    let systemImage: String
    let action: () -> Void
    @FocusState private var isFocused: Bool

    var body: some View {
        Button(action: action) {
            ZStack(alignment: .bottomLeading) {
                RemoteImage(url: imageURL, targetSize: CardSize.landscape, systemImage: systemImage)
                    .frame(width: CardSize.landscape.width, height: CardSize.landscape.height)
                LinearGradient(colors: [.clear, .black.opacity(0.7)], startPoint: .center, endPoint: .bottom)
                Text(title)
                    .font(Typography.sectionTitle)
                    .foregroundStyle(.white)
                    .padding(Spacing.m)
                    .lineLimit(1)
            }
            .frame(width: CardSize.landscape.width, height: CardSize.landscape.height)
            .clipShape(RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
        }
        .buttonStyle(CardButtonStyleFoyer())
        .focused($isFocused)
        .accessibilityLabel(title)
    }
}

struct PersonCard: View {
    let person: Person
    let imageURL: URL?

    var body: some View {
        VStack(spacing: Spacing.s) {
            RemoteImage(url: imageURL, targetSize: CGSize(width: CardSize.personAvatar, height: CardSize.personAvatar), systemImage: "person.fill")
                .frame(width: CardSize.personAvatar, height: CardSize.personAvatar)
                .clipShape(Circle())
            Text(person.name ?? "")
                .font(Typography.cardSubtitle)
                .foregroundStyle(Color.foyerPrimaryText)
                .lineLimit(1)
            if let role = person.role, !role.isEmpty {
                Text(role)
                    .font(Typography.caption)
                    .foregroundStyle(Color.foyerTertiaryText)
                    .lineLimit(1)
            }
        }
        .frame(width: CardSize.personAvatar + 40)
        .focusable()
        .accessibilityElement(children: .combine)
    }
}
