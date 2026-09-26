import SwiftUI
import FoyerFoundation
import JellyfinKit
import PlaybackDecision

/// Series → seasons → episodes on one screen. The primary button always knows where you are.
struct SeriesDetailView: View {
    let seriesId: String
    @State private var model: SeriesViewModel
    @Environment(AppEnvironment.self) private var environment
    @State private var showOverview = false
    @Namespace private var focusNamespace

    init(seriesId: String, initialSeries: BaseItem?, initialSeasonId: String? = nil) {
        self.seriesId = seriesId
        _model = State(initialValue: SeriesViewModel(seriesId: seriesId, initialSeries: initialSeries, initialSeasonId: initialSeasonId))
    }

    private var images: ItemImages? { environment.client.map(ItemImages.init) }

    var body: some View {
        ZStack {
            HeroBackdrop(url: model.series.flatMap { images?.backdrop($0) }, opacity: 0.55)
            if model.series == nil, model.isLoading {
                LoadingView()
            } else if model.series == nil, let error = model.error {
                ErrorStateView(error: error) {
                    Task { if let client = environment.client { await model.load(client: client) } }
                }
            } else {
                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: Spacing.l) {
                        header
                            .padding(.horizontal, Spacing.screenEdge)
                            .padding(.top, Spacing.xl)
                        seasonPicker
                        episodeList
                    }
                    .padding(.bottom, Spacing.xl)
                }
                .scrollClipDisabled()
            }
        }
        .task(id: seriesId) {
            if let client = environment.client { await model.load(client: client) }
        }
        .onChange(of: environment.playback == nil) { _, closed in
            if closed { Task { await model.refreshAfterPlayback() } }
        }
        .sheet(isPresented: $showOverview) {
            OverviewSheet(title: model.series?.displayTitle ?? "", text: model.series?.overview ?? "")
        }
        .accessibilityIdentifier("seriesDetail")
    }

    // MARK: Header

    @ViewBuilder private var header: some View {
        if let series = model.series {
            VStack(alignment: .leading, spacing: Spacing.m) {
                if let logo = images?.logo(series) {
                    RemoteImage(url: logo, targetSize: CGSize(width: 700, height: 260), contentMode: .fit) {
                        Text(series.displayTitle).font(Typography.heroTitle)
                    }
                    .frame(maxWidth: 700, maxHeight: 220, alignment: .leading)
                    .accessibilityLabel(series.displayTitle)
                } else {
                    Text(series.displayTitle).font(Typography.heroTitle).lineLimit(2)
                }
                HStack(spacing: Spacing.s) {
                    Text(series.seriesMetaLine)
                    if let rating = series.ratingText { Label(rating, systemImage: "star.fill") }
                    if let genres = series.genres, !genres.isEmpty {
                        Text(genres.prefix(3).joined(separator: ", ")).foregroundStyle(Color.foyerTertiaryText)
                    }
                }
                .font(Typography.meta)
                .foregroundStyle(Color.foyerSecondaryText)

                if let overview = series.overview, !overview.isEmpty {
                    Button { showOverview = true } label: {
                        Text(overview)
                            .font(Typography.body)
                            .foregroundStyle(Color.foyerSecondaryText)
                            .lineLimit(3)
                            .multilineTextAlignment(.leading)
                            .frame(maxWidth: 1100, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                }

                HStack(spacing: Spacing.m) {
                    if let episode = model.primaryEpisode, let title = model.primaryActionTitle {
                        Button {
                            environment.play(episode, start: .automatic)
                        } label: {
                            Label(title, systemImage: "play.fill")
                        }
                        .buttonStyle(PillButtonStyle())
                        .prefersDefaultFocus(in: focusNamespace)
                        .accessibilityIdentifier("seriesPlayButton")
                    }
                    if model.allWatched {
                        Label(L10n.allEpisodesWatched, systemImage: "checkmark.circle.fill")
                            .font(Typography.meta)
                            .foregroundStyle(Color.foyerSecondaryText)
                    }
                }
                .focusScope(focusNamespace)
            }
        }
    }

    // MARK: Seasons

    private var seasonPicker: some View {
        ScrollView(.horizontal) {
            HStack(spacing: Spacing.s) {
                ForEach(model.seasons) { season in
                    SeasonChip(title: model.seasonTitle(season),
                               unwatched: season.userData?.unplayedItemCount ?? 0,
                               isSelected: season.id == model.selectedSeasonId) {
                        model.selectedSeasonId = season.id
                    }
                }
            }
            .padding(.horizontal, Spacing.screenEdge)
            .padding(.vertical, Spacing.s)
        }
        .scrollClipDisabled()
        .focusSection()
        .accessibilityIdentifier("seasonPicker")
    }

    // MARK: Episodes

    @ViewBuilder private var episodeList: some View {
        if model.selectedEpisodes.isEmpty {
            if model.loadingSeasonId != nil || model.isLoading {
                ProgressView().padding(.horizontal, Spacing.screenEdge)
            } else {
                Text(L10n.libraryEmpty)
                    .font(Typography.body)
                    .foregroundStyle(Color.foyerSecondaryText)
                    .padding(.horizontal, Spacing.screenEdge)
            }
        } else {
            LazyVStack(alignment: .leading, spacing: Spacing.m) {
                ForEach(model.selectedEpisodes) { episode in
                    EpisodeRow(episode: episode, imageURL: images?.landscape(episode, width: 800)) {
                        environment.play(episode, start: .automatic)
                    }
                    .contextMenu {
                        NavigationLink(value: NavigationTarget(item: episode)) {
                            Label(L10n.details, systemImage: "info.circle")
                        }
                        Button { environment.play(episode, start: .beginning) } label: {
                            Label(L10n.playFromBeginning, systemImage: "gobackward")
                        }
                        Button { Task { await model.togglePlayed(episode) } } label: {
                            Label(episode.isPlayed ? L10n.markUnwatched : L10n.markWatched, systemImage: episode.isPlayed ? "eye.slash" : "eye")
                        }
                    }
                }
            }
            .padding(.horizontal, Spacing.screenEdge)
            .focusSection()
        }
    }
}

private struct SeasonChip: View {
    let title: String
    let unwatched: Int
    let isSelected: Bool
    let action: () -> Void
    @FocusState private var isFocused: Bool

    var body: some View {
        Button(action: action) {
            HStack(spacing: Spacing.xs) {
                Text(title)
                if unwatched > 0 {
                    Text("\(unwatched)")
                        .font(Typography.caption)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(isFocused ? Color.black.opacity(0.15) : Color.foyerAccent))
                        .foregroundStyle(isFocused ? .black : .black)
                }
            }
            .font(Typography.meta)
            .padding(.horizontal, Spacing.m)
            .padding(.vertical, Spacing.s)
            .background(Capsule().fill(isFocused ? Color.white : (isSelected ? Color.white.opacity(0.22) : Color.white.opacity(0.08))))
            .foregroundStyle(isFocused ? Color.black : Color.foyerPrimaryText)
            .scaleEffect(isFocused ? 1.05 : 1)
            .animation(Motion.focus, value: isFocused)
        }
        .buttonStyle(.plain)
        .focused($isFocused)
        .onChange(of: isFocused) { _, focused in
            // Focusing a season shows its episodes; no extra click needed.
            if focused { action() }
        }
        .accessibilityLabel(title)
        .accessibilityValue(unwatched > 0 ? "\(unwatched)" : "")
    }
}

struct EpisodeRow: View {
    let episode: BaseItem
    let imageURL: URL?
    let action: () -> Void
    @FocusState private var isFocused: Bool

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: Spacing.m) {
                ZStack(alignment: .bottom) {
                    RemoteImage(url: imageURL, targetSize: CardSize.landscape, systemImage: "play.rectangle")
                        .frame(width: CardSize.landscape.width, height: CardSize.landscape.height)
                    if let percent = episode.playedPercentage {
                        ProgressBar(fraction: percent / 100)
                            .padding(.horizontal, Spacing.s)
                            .padding(.bottom, Spacing.s)
                    }
                }
                .frame(width: CardSize.landscape.width, height: CardSize.landscape.height)
                .clipShape(RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
                .overlay(alignment: .topTrailing) {
                    if episode.isPlayed {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 26))
                            .foregroundStyle(.white, Color.foyerAccent)
                            .padding(Spacing.xs)
                    }
                }

                VStack(alignment: .leading, spacing: Spacing.xs) {
                    HStack(spacing: Spacing.s) {
                        if let number = episode.indexNumber {
                            Text("\(number)")
                                .font(Typography.cardTitle)
                                .foregroundStyle(isFocused ? Color.black.opacity(0.6) : Color.foyerAccent)
                        }
                        Text(episode.displayTitle)
                            .font(Typography.cardTitle)
                            .lineLimit(1)
                    }
                    HStack(spacing: Spacing.s) {
                        if let runtime = episode.runtimeText { Text(runtime) }
                        if let date = episode.premiereDate { Text(date.formatted(date: .abbreviated, time: .omitted)) }
                    }
                    .font(Typography.caption)
                    .foregroundStyle(isFocused ? Color.black.opacity(0.6) : Color.foyerTertiaryText)
                    if let overview = episode.overview, !overview.isEmpty {
                        Text(overview)
                            .font(Typography.cardSubtitle)
                            .foregroundStyle(isFocused ? Color.black.opacity(0.75) : Color.foyerSecondaryText)
                            .lineLimit(3)
                            .multilineTextAlignment(.leading)
                    }
                }
                .padding(.vertical, Spacing.xs)
                Spacer(minLength: 0)
            }
            .padding(Spacing.s)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: Radius.panel, style: .continuous).fill(isFocused ? Color.white : Color.white.opacity(0.05)))
            .foregroundStyle(isFocused ? Color.black : Color.foyerPrimaryText)
            .scaleEffect(isFocused ? 1.015 : 1)
            .animation(Motion.focus, value: isFocused)
        }
        .buttonStyle(.plain)
        .focused($isFocused)
        .accessibilityLabel("\(episode.episodeLabel ?? "") \(episode.displayTitle)")
        .accessibilityValue(episode.isPlayed ? L10n.watched : (episode.playedPercentage.map { "\(Int($0)) %" } ?? ""))
    }
}
