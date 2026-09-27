import SwiftUI
import VelaFoundation
import JellyfinKit

/// Movie / episode detail. Play is the hero action; everything else stays out of the way.
struct ItemDetailView: View {
    let itemId: String
    @State private var model: ItemDetailViewModel
    @Environment(AppEnvironment.self) private var environment
    @State private var showOverview = false
    @State private var showTechnicalInfo = false
    @Namespace private var focusNamespace

    init(itemId: String, initialItem: BaseItem?) {
        self.itemId = itemId
        _model = State(initialValue: ItemDetailViewModel(item: initialItem ?? BaseItem(id: itemId)))
    }

    private var images: ItemImages? { environment.client.map(ItemImages.init) }

    var body: some View {
        ZStack {
            HeroBackdrop(url: images?.backdrop(model.item), opacity: 0.6)
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: Spacing.rowGap) {
                    header
                        .padding(.horizontal, Spacing.screenEdge)
                        .padding(.top, Spacing.xl)
                    if !model.item.actors.isEmpty {
                        castRow
                    }
                    if !model.similar.isEmpty {
                        MediaRow(title: L10n.similar, items: model.similar) { item in
                            PosterCard(item: item, imageURL: images?.poster(item, width: 480), showProgress: false) {
                                navigate(to: item)
                            }
                        }
                    }
                }
                .padding(.bottom, Spacing.xl)
            }
            .scrollClipDisabled()
            if let error = model.error, !model.loadedFullIndicator {
                ErrorStateView(error: error) {
                    Task { if let client = environment.client { await model.load(client: client, force: true) } }
                }
                .background(Color.velaBackground.opacity(0.8))
            }
        }
        .focusScope(focusNamespace)
        .task(id: itemId) {
            if let client = environment.client { await model.load(client: client) }
        }
        .onChange(of: environment.playback == nil) { _, closed in
            if closed, let client = environment.client {
                Task { await model.refreshUserData(client: client) }
            }
        }
        .sheet(isPresented: $showOverview) {
            OverviewSheet(title: model.item.displayTitle, text: model.item.overview ?? "")
        }
        .sheet(isPresented: $showTechnicalInfo) {
            TechnicalInfoSheet(item: model.item, source: model.selectedSource)
        }
        .navigationDestination(item: $pendingNavigation) { target in
            ItemDestination(item: target.item)
        }
        .accessibilityIdentifier("itemDetail")
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .top, spacing: Spacing.xl) {
            RemoteImage(url: images?.poster(model.item, width: 600), targetSize: CGSize(width: 300, height: 450))
                .frame(width: 300, height: 450)
                .clipShape(RoundedRectangle(cornerRadius: Radius.poster, style: .continuous))
                .shadow(color: .black.opacity(0.5), radius: 30, y: 16)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: Spacing.m) {
                titleBlock
                metaBlock
                if let overview = model.item.overview, !overview.isEmpty {
                    Button {
                        showOverview = true
                    } label: {
                        Text(overview)
                            .font(Typography.body)
                            .foregroundStyle(Color.velaSecondaryText)
                            .lineLimit(4)
                            .multilineTextAlignment(.leading)
                            .frame(maxWidth: 1000, alignment: .leading)
                    }
                    .buttonStyle(TextBlockButtonStyle())
                    .accessibilityHint(L10n.more)
                }
                creditsBlock
                actionRow
                    .padding(.top, Spacing.s)
            }
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder private var titleBlock: some View {
        if model.item.isEpisode {
            VStack(alignment: .leading, spacing: 6) {
                Text(model.item.seriesName ?? "")
                    .font(Typography.meta)
                    .foregroundStyle(Color.velaAccent)
                Text(model.item.displayTitle)
                    .font(Typography.screenTitle)
                    .lineLimit(2)
                if let label = model.item.episodeLabel {
                    Text(label + (model.item.seasonName.map { " · \($0)" } ?? ""))
                        .font(Typography.meta)
                        .foregroundStyle(Color.velaSecondaryText)
                }
            }
        } else if let logo = images?.logo(model.item) {
            RemoteImage(url: logo, targetSize: CGSize(width: 700, height: 260), contentMode: .fit) {
                Text(model.item.displayTitle).font(Typography.heroTitle)
            }
            .frame(maxWidth: 700, maxHeight: 220, alignment: .leading)
            .accessibilityLabel(model.item.displayTitle)
        } else {
            Text(model.item.displayTitle)
                .font(Typography.heroTitle)
                .lineLimit(2)
        }
    }

    private var metaBlock: some View {
        HStack(spacing: Spacing.s) {
            Text(model.item.metaLine)
                .font(Typography.meta)
                .foregroundStyle(Color.velaSecondaryText)
            if let rating = model.item.ratingText {
                Label(rating, systemImage: "star.fill")
                    .font(Typography.meta)
                    .foregroundStyle(Color.velaSecondaryText)
            }
            if environment.preferences.showTechnicalBadges {
                ForEach(model.item.technicalBadges, id: \.self) { MetaBadge(text: $0) }
            }
            if let genres = model.item.genres, !genres.isEmpty {
                Text(genres.prefix(3).joined(separator: ", "))
                    .font(Typography.meta)
                    .foregroundStyle(Color.velaTertiaryText)
                    .lineLimit(1)
            }
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private var creditsBlock: some View {
        let directors = model.item.directors.compactMap(\.name)
        if !directors.isEmpty {
            HStack(spacing: Spacing.xs) {
                Text(L10n.director + ":").foregroundStyle(Color.velaTertiaryText)
                Text(directors.prefix(2).joined(separator: ", "))
            }
            .font(Typography.meta)
            .foregroundStyle(Color.velaSecondaryText)
        }
    }

    private var actionRow: some View {
        HStack(spacing: Spacing.m) {
            Button {
                environment.play(model.item, mediaSourceId: model.selectedMediaSourceId, start: .automatic)
            } label: {
                Label(model.primaryActionTitle, systemImage: "play.fill")
            }
            .buttonStyle(PillButtonStyle())
            .prefersDefaultFocus(in: focusNamespace)
            .accessibilityIdentifier("playButton")

            if model.canResume {
                Button {
                    environment.play(model.item, mediaSourceId: model.selectedMediaSourceId, start: .beginning)
                } label: {
                    Image(systemName: "gobackward")
                }
                .buttonStyle(IconButtonStyle())
                .accessibilityLabel(L10n.playFromBeginning)
            }

            Button {
                Task { if let client = environment.client { await model.togglePlayed(client: client) } }
            } label: {
                Image(systemName: model.item.isPlayed ? "checkmark.circle.fill" : "checkmark.circle")
            }
            .buttonStyle(IconButtonStyle())
            .accessibilityLabel(model.item.isPlayed ? L10n.markUnwatched : L10n.markWatched)
            .accessibilityIdentifier("watchedButton")

            Button {
                Task { if let client = environment.client { await model.toggleFavorite(client: client) } }
            } label: {
                Image(systemName: model.item.isFavorite ? "heart.fill" : "heart")
            }
            .buttonStyle(IconButtonStyle())
            .accessibilityLabel(model.item.isFavorite ? L10n.removeFavorite : L10n.addFavorite)

            if let sources = model.item.mediaSources, sources.count > 1 {
                Menu {
                    ForEach(sources) { source in
                        Button {
                            model.selectedMediaSourceId = source.id
                        } label: {
                            if source.id == model.selectedMediaSourceId {
                                Label(versionTitle(source), systemImage: "checkmark")
                            } else {
                                Text(versionTitle(source))
                            }
                        }
                    }
                } label: {
                    Label(model.selectedSource.map(versionTitle) ?? L10n.version, systemImage: "square.stack")
                        .font(Typography.meta)
                }
                .accessibilityLabel(L10n.versions)
            }

            Button {
                showTechnicalInfo = true
            } label: {
                Image(systemName: "info")
            }
            .buttonStyle(IconButtonStyle())
            .accessibilityLabel(L10n.technicalInfo)

            if model.item.isEpisode, let series = model.series ?? model.item.seriesId.map({ BaseItem(id: $0, name: model.item.seriesName, type: .series) }) {
                NavigationLink(value: NavigationTarget(item: series)) {
                    Label(model.item.seriesName ?? L10n.shows, systemImage: "tv")
                        .font(Typography.meta)
                }
                .buttonStyle(PillButtonStyle(prominent: false))
            }
        }
        .focusSection()
    }

    private var castRow: some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            SectionHeader(title: L10n.cast)
            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: Spacing.m) {
                    ForEach(Array(model.item.actors.prefix(20).enumerated()), id: \.offset) { _, person in
                        PersonCard(person: person, imageURL: images?.person(person))
                    }
                }
                .padding(.horizontal, Spacing.screenEdge)
                .padding(.vertical, Spacing.s)
            }
            .scrollClipDisabled()
        }
        .focusSection()
    }

    private func versionTitle(_ source: MediaSource) -> String {
        if let name = source.name, !name.isEmpty { return name }
        var parts: [String] = []
        if let video = source.videoStream { parts.append(video.technicalLabel) }
        if let container = source.containerTokens.first { parts.append(container.uppercased()) }
        return parts.isEmpty ? source.id : parts.joined(separator: " · ")
    }

    @State private var pendingNavigation: NavigationTarget?

    private func navigate(to item: BaseItem) {
        pendingNavigation = NavigationTarget(item: item)
    }
}

private extension ItemDetailViewModel {
    var loadedFullIndicator: Bool { item.overview != nil || item.mediaSources != nil }
}

struct OverviewSheet: View {
    let title: String
    let text: String

    var body: some View {
        ZStack {
            Color.velaBackground.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.m) {
                    Text(title).font(Typography.screenTitle)
                    Text(text)
                        .font(Typography.body)
                        .foregroundStyle(Color.velaSecondaryText)
                        .frame(maxWidth: 1300, alignment: .leading)
                }
                .padding(Spacing.xl)
            }
            .focusable()
        }
    }
}

struct TechnicalInfoSheet: View {
    let item: BaseItem
    let source: MediaSource?
    @Environment(AppEnvironment.self) private var environment

    var body: some View {
        ZStack {
            Color.velaBackground.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.l) {
                    Text(L10n.technicalInfo).font(Typography.screenTitle)
                    if let source {
                        group(L10n.container, [[source.containerTokens.first?.uppercased() ?? "?",
                                                 source.size.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "",
                                                 source.bitrate.map { "\($0 / 1_000_000) Mbit/s" } ?? ""].filter { !$0.isEmpty }.joined(separator: " · ")])
                        if let video = source.videoStream {
                            group(L10n.video, [videoDescription(video)])
                        }
                        group(L10n.audio, source.audioStreams.map(trackDescription))
                        group(L10n.subtitles, source.subtitleStreams.isEmpty ? [L10n.none] : source.subtitleStreams.map(trackDescription))
                        if environment.preferences.debugModeEnabled, let path = source.path {
                            group("Path", [path])
                        }
                    } else {
                        Text(L10n.none).foregroundStyle(Color.velaSecondaryText)
                    }
                }
                .padding(Spacing.xl)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .focusable()
        }
    }

    private func group(_ title: String, _ lines: [String]) -> some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            Text(title).font(Typography.meta).foregroundStyle(Color.velaTertiaryText)
            ForEach(lines, id: \.self) { line in
                Text(line).font(Typography.body)
            }
        }
    }

    private func videoDescription(_ video: MediaStream) -> String {
        var parts = [video.technicalLabel]
        if let w = video.width, let h = video.height { parts.append("\(w)×\(h)") }
        if let fps = video.frameRate { parts.append(String(format: "%.3f fps", fps)) }
        if let depth = video.bitDepth { parts.append("\(depth)-bit") }
        if let profile = video.profile { parts.append(profile) }
        if let tag = video.codecTag { parts.append(tag) }
        if let rate = video.bitRate { parts.append("\(rate / 1_000_000) Mbit/s") }
        return parts.joined(separator: " · ")
    }

    private func trackDescription(_ stream: MediaStream) -> String {
        var parts: [String] = []
        parts.append(LanguageCode.displayName(stream.language) ?? L10n.unknownLanguage)
        parts.append(stream.technicalLabel)
        if let title = stream.title, !title.isEmpty { parts.append(title) }
        if stream.isForced == true { parts.append(L10n.forced) }
        if stream.isSDH { parts.append(L10n.sdh) }
        if stream.isExternal == true { parts.append(L10n.external) }
        if stream.isDefault == true { parts.append("Default") }
        return parts.joined(separator: " · ")
    }
}
