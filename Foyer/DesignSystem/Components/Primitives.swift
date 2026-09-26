import SwiftUI

struct ProgressBar: View {
    let fraction: Double
    var height: CGFloat = 6

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.3))
                Capsule().fill(Color.foyerProgress)
                    .frame(width: max(height, geo.size.width * min(max(fraction, 0), 1)))
            }
        }
        .frame(height: height)
        .accessibilityHidden(true)
    }
}

struct MetaBadge: View {
    let text: String
    var body: some View {
        Text(text)
            .font(Typography.caption)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(RoundedRectangle(cornerRadius: Radius.badge).fill(Color.white.opacity(0.18)))
            .overlay(RoundedRectangle(cornerRadius: Radius.badge).stroke(Color.white.opacity(0.35), lineWidth: 1))
            .foregroundStyle(Color.foyerPrimaryText)
    }
}

struct SectionHeader: View {
    let title: String
    var subtitle: String? = nil

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.s) {
            Text(title)
                .font(Typography.sectionTitle)
                .foregroundStyle(Color.foyerPrimaryText)
            if let subtitle {
                Text(subtitle)
                    .font(Typography.meta)
                    .foregroundStyle(Color.foyerTertiaryText)
            }
            Spacer()
        }
        .padding(.horizontal, Spacing.screenEdge)
        .accessibilityAddTraits(.isHeader)
    }
}

/// Horizontal row of cards with lazy loading and a focus section so vertical
/// navigation lands on the last focused card.
struct MediaRow<Item: Identifiable & Hashable, Content: View>: View {
    let title: String
    var subtitle: String? = nil
    let items: [Item]
    @ViewBuilder let content: (Item) -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            SectionHeader(title: title, subtitle: subtitle)
            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: Spacing.l) {
                    ForEach(items) { item in
                        content(item)
                    }
                }
                .padding(.horizontal, Spacing.screenEdge)
                .padding(.vertical, Spacing.m)
            }
            .scrollClipDisabled()
        }
        .focusSection()
    }
}

struct LoadingView: View {
    var text: String? = nil
    var body: some View {
        VStack(spacing: Spacing.m) {
            ProgressView()
                .scaleEffect(1.4)
            if let text {
                Text(text)
                    .font(Typography.meta)
                    .foregroundStyle(Color.foyerSecondaryText)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct ErrorStateView: View {
    let error: any Error
    var retry: (() -> Void)? = nil
    @Environment(AppEnvironment.self) private var environment

    var body: some View {
        let presentation = ErrorPresentation(error)
        VStack(spacing: Spacing.m) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 60, weight: .light))
                .foregroundStyle(Color.foyerSecondaryText)
            Text(presentation.title)
                .font(Typography.sectionTitle)
            Text(presentation.message)
                .font(Typography.body)
                .foregroundStyle(Color.foyerSecondaryText)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 900)
            if environment.preferences.debugModeEnabled {
                Text(FoyerErrorDetail.text(error))
                    .font(Typography.mono)
                    .foregroundStyle(Color.foyerTertiaryText)
                    .frame(maxWidth: 1100)
                    .lineLimit(4)
            }
            if let retry, presentation.canRetry {
                Button(L10n.retry, action: retry)
                    .buttonStyle(PillButtonStyle())
                    .padding(.top, Spacing.s)
            }
        }
        .padding(Spacing.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

enum FoyerErrorDetail {
    static func text(_ error: any Error) -> String {
        let wrapped = FoyerFoundationErrorBridge.detail(error)
        return wrapped
    }
}

struct EmptyStateView: View {
    let systemImage: String
    let text: String

    var body: some View {
        VStack(spacing: Spacing.m) {
            Image(systemName: systemImage)
                .font(.system(size: 60, weight: .light))
                .foregroundStyle(Color.foyerTertiaryText)
            Text(text)
                .font(Typography.body)
                .foregroundStyle(Color.foyerSecondaryText)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 900)
        }
        .padding(Spacing.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Full-bleed backdrop with gradient scrim so text stays readable.
struct HeroBackdrop: View {
    let url: URL?
    var opacity: Double = 1
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        ZStack {
            Color.foyerBackground
            RemoteImage(url: url, targetSize: CGSize(width: 1920, height: 1080)) {
                Color.foyerBackground
            }
            .opacity(reduceTransparency ? 0.35 : opacity)
            LinearGradient(colors: [.clear, Color.foyerBackground.opacity(0.75), Color.foyerBackground],
                           startPoint: .top, endPoint: .bottom)
            LinearGradient(colors: [Color.foyerBackground.opacity(0.85), .clear],
                           startPoint: .leading, endPoint: .center)
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }
}
