import SwiftUI
import Observation
import FoyerFoundation
import JellyfinKit
import PlaybackDecision

/// Foyer's own transport UI for the advanced engine, modelled on the tvOS player:
/// click to show controls, swipe to scrub, swipe down for the info/track panel,
/// Menu to hide or leave.
struct AdvancedPlayerOverlay: View {
    let coordinator: PlaybackCoordinator
    @Environment(AppEnvironment.self) private var environment
    @State private var model = OverlayModel()

    var body: some View {
        ZStack {
            RemoteInputView(isEnabled: model.panel == nil, handlers: handlers)
                .accessibilityHidden(true)

            if model.panel == nil {
                if model.isVisible || model.isScrubbing {
                    chrome
                        .transition(.opacity)
                }
                if coordinator.isBuffering, !model.isScrubbing {
                    ProgressView()
                        .scaleEffect(1.6)
                        .tint(.white)
                        .transition(.opacity)
                }
                bottomTrailingPrompts
                if environment.preferences.debugModeEnabled, model.isVisible {
                    debugHUD
                }
            } else if let panel = model.panel {
                PlayerPanelView(coordinator: coordinator, panel: panel) {
                    model.closePanel()
                    model.show(playing: coordinator.isPlaying)
                }
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(Motion.overlay, value: model.isVisible)
        .animation(Motion.overlay, value: model.panel)
        .onChange(of: model.isVisible || model.isScrubbing || model.panel != nil) { _, covered in
            coordinator.setControlsVisible(covered)
        }
        .onChange(of: coordinator.isPlaying) { _, playing in
            if playing { model.scheduleHide() } else { model.show(playing: false) }
        }
        .onChange(of: coordinator.engineState) { _, state in
            if case .failed = state { model.isVisible = false }
        }
        .onAppear { model.show(playing: coordinator.isPlaying) }
    }

    // MARK: Input

    private var handlers: RemoteInputView.Handlers {
        RemoteInputView.Handlers(
            onSelect: {
                if model.isScrubbing {
                    commitScrub()
                } else if case .none = coordinator.skipPrompt, !model.isVisible {
                    model.show(playing: coordinator.isPlaying)
                } else if !model.isVisible {
                    coordinator.performSkip()
                } else if coordinator.countdownSeconds != nil {
                    coordinator.playNext()
                } else {
                    coordinator.togglePlayPause()
                    model.show(playing: !coordinator.isPlaying)
                }
            },
            onLongSelect: {
                model.openPanel(.info)
            },
            onPlayPause: {
                if model.isScrubbing {
                    commitScrub()
                } else {
                    coordinator.togglePlayPause()
                    model.show(playing: !coordinator.isPlaying)
                }
            },
            onMenu: {
                if model.isScrubbing {
                    model.cancelScrub()
                } else if coordinator.countdownSeconds != nil {
                    coordinator.cancelCountdown()
                } else if model.isVisible {
                    model.hide()
                } else {
                    coordinator.close()
                }
            },
            onLeft: { nudge(-10) },
            onRight: { nudge(10) },
            onUp: {
                if !model.isVisible { model.show(playing: coordinator.isPlaying) }
            },
            onDown: {
                if model.isVisible || coordinator.isPlaying { model.openPanel(.info) }
            },
            onPan: { translation, ended in
                handlePan(translation, ended: ended)
            },
            onTouchesBegan: {
                if !model.isVisible, !model.isScrubbing { model.show(playing: coordinator.isPlaying) }
            }
        )
    }

    private func nudge(_ seconds: TimeInterval) {
        if model.isScrubbing {
            model.scrubTarget = clamp((model.scrubTarget ?? coordinator.currentTime) + seconds)
        } else {
            coordinator.seek(by: seconds)
            model.show(playing: coordinator.isPlaying)
        }
    }

    private func handlePan(_ translation: CGPoint, ended: Bool) {
        // Vertical swipe down opens the panel when not scrubbing.
        if !model.isScrubbing, translation.y > 140, abs(translation.x) < 100 {
            if ended { model.openPanel(.info) }
            return
        }
        guard coordinator.duration > 0 else { return }
        if !model.isScrubbing {
            guard abs(translation.x) > 24 else { return }
            model.beginScrub(at: coordinator.currentTime)
        }
        // A full swipe across the touch surface moves ~10 % of the runtime (1–15 min).
        let span = min(max(coordinator.duration * 0.1, 60), 900)
        let base = model.scrubBase ?? coordinator.currentTime
        model.scrubTarget = clamp(base + Double(translation.x) / 1000 * span)
        if ended {
            // Keep the target visible; the user confirms with select (or continues swiping).
            model.scrubBase = model.scrubTarget
        }
    }

    private func commitScrub() {
        guard let target = model.scrubTarget else { return }
        coordinator.seek(to: target)
        model.endScrub()
        model.show(playing: coordinator.isPlaying)
    }

    private func clamp(_ t: TimeInterval) -> TimeInterval {
        max(0, min(t, max(0, coordinator.duration - 1)))
    }

    // MARK: Chrome

    private var chrome: some View {
        VStack {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 6) {
                    if coordinator.item.isEpisode, let series = coordinator.item.seriesName {
                        Text(series).font(Typography.meta).foregroundStyle(Color.foyerSecondaryText)
                    }
                    Text(coordinator.item.isEpisode ? (coordinator.item.name ?? "") : coordinator.item.displayTitle)
                        .font(Typography.sectionTitle)
                    if coordinator.item.isEpisode, let label = coordinator.item.episodeLabel {
                        Text(label).font(Typography.meta).foregroundStyle(Color.foyerSecondaryText)
                    }
                }
                Spacer()
                if coordinator.duration > 0 {
                    Text(L10n.endsAt(DurationFormatting.clockTime(Date().addingTimeInterval(coordinator.duration - (model.scrubTarget ?? coordinator.currentTime)))))
                        .font(Typography.meta)
                        .foregroundStyle(Color.foyerSecondaryText)
                }
            }
            .padding(.horizontal, 90)
            .padding(.top, 60)
            .background(LinearGradient(colors: [.black.opacity(0.6), .clear], startPoint: .top, endPoint: .bottom).ignoresSafeArea())

            Spacer()

            VStack(spacing: Spacing.s) {
                if model.isScrubbing, let target = model.scrubTarget {
                    ScrubPreview(coordinator: coordinator, time: target)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 90)
                }
                ScrubberBar(current: model.scrubTarget ?? coordinator.currentTime,
                            duration: coordinator.duration,
                            buffered: coordinator.statistics.bufferedSeconds,
                            chapters: coordinator.chapters.map(\.start),
                            isScrubbing: model.isScrubbing)
                    .frame(height: 10)
                    .padding(.horizontal, 90)
                HStack {
                    HStack(spacing: Spacing.s) {
                        Image(systemName: coordinator.isPlaying ? "play.fill" : "pause.fill")
                            .font(.system(size: 22, weight: .semibold))
                        Text((model.scrubTarget ?? coordinator.currentTime).clockString)
                    }
                    Spacer()
                    Text("−" + max(0, coordinator.duration - (model.scrubTarget ?? coordinator.currentTime)).clockString)
                }
                .font(Typography.meta.monospacedDigit())
                .foregroundStyle(Color.foyerSecondaryText)
                .padding(.horizontal, 90)
            }
            .padding(.bottom, 60)
            .padding(.top, 140)
            .background(LinearGradient(colors: [.clear, .black.opacity(0.7)], startPoint: .top, endPoint: .bottom).ignoresSafeArea())
        }
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder private var bottomTrailingPrompts: some View {
        VStack {
            Spacer()
            HStack {
                Spacer()
                if let seconds = coordinator.countdownSeconds, let next = coordinator.nextEpisode {
                    NextEpisodeCard(episode: next, seconds: seconds, imageURL: environment.client.flatMap { ItemImages(client: $0).landscape(next, width: 600) })
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                } else if let title = skipTitle {
                    SkipPill(title: title)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
            .padding(.trailing, 90)
            .padding(.bottom, model.isVisible ? 200 : 80)
        }
        .animation(Motion.overlay, value: coordinator.countdownSeconds)
        .animation(Motion.overlay, value: skipTitle)
    }

    private var skipTitle: String? {
        switch coordinator.skipPrompt {
        case .none: nil
        case .skipIntro: L10n.skipIntro
        case .skipRecap: L10n.skipRecap
        case .skipCommercial: L10n.skipAd
        case .nextEpisode: coordinator.nextEpisode != nil ? L10n.nextEpisode : nil
        }
    }

    private var debugHUD: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let decision = coordinator.decision {
                Text(decision.route.displayName).font(Typography.mono).bold()
            }
            ForEach(coordinator.statistics.lines, id: \.self) { line in
                Text(line).font(Typography.mono)
            }
        }
        .foregroundStyle(.white.opacity(0.85))
        .padding(Spacing.s)
        .background(RoundedRectangle(cornerRadius: 10).fill(.black.opacity(0.55)))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(.top, 200)
        .padding(.leading, 90)
        .allowsHitTesting(false)
    }
}

// MARK: - Overlay state

@MainActor
@Observable
final class OverlayModel {
    enum Panel: Hashable { case info, audio, subtitles, chapters }

    var isVisible = false
    var panel: Panel?
    var isScrubbing = false
    var scrubTarget: TimeInterval?
    var scrubBase: TimeInterval?
    private var hideTask: Task<Void, Never>?

    func show(playing: Bool) {
        isVisible = true
        if playing { scheduleHide() } else { hideTask?.cancel() }
    }

    func hide() {
        hideTask?.cancel()
        isVisible = false
    }

    func scheduleHide(after seconds: TimeInterval = 4) {
        hideTask?.cancel()
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard let self, !Task.isCancelled, !self.isScrubbing else { return }
            self.isVisible = false
        }
    }

    func beginScrub(at time: TimeInterval) {
        hideTask?.cancel()
        isScrubbing = true
        isVisible = true
        scrubBase = time
        scrubTarget = time
    }

    func endScrub() {
        isScrubbing = false
        scrubTarget = nil
        scrubBase = nil
    }

    func cancelScrub() {
        endScrub()
        scheduleHide()
    }

    func openPanel(_ panel: Panel) {
        hideTask?.cancel()
        endScrub()
        isVisible = false
        self.panel = panel
    }

    func closePanel() {
        panel = nil
    }
}

// MARK: - Pieces

struct ScrubberBar: View {
    let current: TimeInterval
    let duration: TimeInterval
    let buffered: TimeInterval
    let chapters: [TimeInterval]
    let isScrubbing: Bool

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let fraction = duration > 0 ? min(max(current / duration, 0), 1) : 0
            let bufferedFraction = duration > 0 ? min(max((current + buffered) / duration, 0), 1) : 0
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.25))
                Capsule().fill(Color.white.opacity(0.35)).frame(width: width * bufferedFraction)
                Capsule().fill(Color.white).frame(width: max(6, width * fraction))
                ForEach(chapters.indices, id: \.self) { index in
                    let start = chapters[index]
                    if duration > 0, start > 0 {
                        Rectangle().fill(Color.black.opacity(0.6)).frame(width: 3, height: 10)
                            .offset(x: width * min(start / duration, 1))
                    }
                }
                Circle()
                    .fill(Color.white)
                    .frame(width: isScrubbing ? 26 : 16, height: isScrubbing ? 26 : 16)
                    .shadow(color: .black.opacity(0.5), radius: 6)
                    .offset(x: max(0, width * fraction - (isScrubbing ? 13 : 8)), y: isScrubbing ? -8 : -3)
            }
        }
        .accessibilityElement()
        .accessibilityLabel("\(current.clockString) / \(duration.clockString)")
    }
}

/// Trickplay thumbnail + timestamp shown above the scrubber while seeking.
struct ScrubPreview: View {
    let coordinator: PlaybackCoordinator
    let time: TimeInterval
    @Environment(\.imagePipeline) private var pipeline
    @State private var tileImage: UIImage?
    @State private var tileIndex: Int = -1

    var body: some View {
        GeometryReader { geo in
            let fraction = coordinator.duration > 0 ? min(max(time / coordinator.duration, 0), 1) : 0
            VStack(spacing: 8) {
                if let geometry = coordinator.trickplay, let tile = geometry.tile(at: time) {
                    ZStack {
                        Rectangle().fill(Color.black)
                        if let cropped = cropped(tile) {
                            Image(uiImage: cropped).resizable().aspectRatio(contentMode: .fill)
                        }
                    }
                    .frame(width: 320, height: 320 * CGFloat(geometry.info.height) / CGFloat(max(1, geometry.info.width)))
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(.white.opacity(0.6), lineWidth: 2))
                    .task(id: tile.imageIndex) {
                        guard tile.imageIndex != tileIndex else { return }
                        if let url = coordinator.trickplayTileURL?(tile.imageIndex),
                           let image = try? await pipeline.image(for: url, targetSize: CGSize(width: 3200, height: 3200)) {
                            tileImage = image
                            tileIndex = tile.imageIndex
                        }
                    }
                }
                Text(time.clockString)
                    .font(Typography.meta.monospacedDigit())
                    .padding(.horizontal, 12)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(.black.opacity(0.7)))
            }
            .frame(width: 320)
            .position(x: min(max(geo.size.width * fraction, 160), geo.size.width - 160), y: geo.size.height / 2)
        }
        .frame(height: 240)
    }

    private func cropped(_ tile: TrickplayGeometry.Tile) -> UIImage? {
        guard let tileImage, let cg = tileImage.cgImage else { return nil }
        let scale = CGFloat(cg.width) / CGFloat(max(1, coordinator.trickplay?.info.tileWidth ?? 1) * max(1, coordinator.trickplay?.info.width ?? 1))
        let rect = CGRect(x: CGFloat(tile.x) * scale, y: CGFloat(tile.y) * scale, width: CGFloat(tile.width) * scale, height: CGFloat(tile.height) * scale)
        guard let croppedCG = cg.cropping(to: rect.integral) else { return nil }
        return UIImage(cgImage: croppedCG)
    }
}

struct SkipPill: View {
    let title: String
    var body: some View {
        HStack(spacing: Spacing.xs) {
            Text(title)
            Image(systemName: "forward.end.fill")
        }
        .font(Typography.button)
        .foregroundStyle(.black)
        .padding(.horizontal, Spacing.l)
        .padding(.vertical, Spacing.s)
        .background(Capsule().fill(.white))
        .shadow(color: .black.opacity(0.4), radius: 16, y: 8)
        .accessibilityLabel(title)
        .accessibilityHint("Select")
    }
}

struct NextEpisodeCard: View {
    let episode: BaseItem
    let seconds: Int
    let imageURL: URL?

    var body: some View {
        HStack(spacing: Spacing.m) {
            RemoteImage(url: imageURL, targetSize: CGSize(width: 260, height: 146), systemImage: "play.rectangle")
                .frame(width: 260, height: 146)
                .clipShape(RoundedRectangle(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 6) {
                Text(L10n.nextEpisodeIn(seconds)).font(Typography.meta).foregroundStyle(Color.foyerSecondaryText)
                Text(episode.episodeLabel ?? "").font(Typography.caption).foregroundStyle(Color.foyerTertiaryText)
                Text(episode.displayTitle).font(Typography.cardTitle).lineLimit(2)
                Text(L10n.playNow + " ▸").font(Typography.caption).foregroundStyle(Color.foyerAccent)
            }
            .frame(width: 360, alignment: .leading)
        }
        .padding(Spacing.m)
        .background(RoundedRectangle(cornerRadius: Radius.panel, style: .continuous).fill(.black.opacity(0.75)))
        .overlay(RoundedRectangle(cornerRadius: Radius.panel, style: .continuous).stroke(.white.opacity(0.15)))
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Panel (info, tracks, chapters)

struct PlayerPanelView: View {
    let coordinator: PlaybackCoordinator
    @State var panel: OverlayModel.Panel
    let close: () -> Void
    @Environment(AppEnvironment.self) private var environment
    @Namespace private var focusNamespace
    @FocusState private var focusedTab: OverlayModel.Panel?

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            HStack(spacing: Spacing.m) {
                tab(.info, L10n.info)
                if coordinator.audioTracks.count > 1 { tab(.audio, L10n.audio) }
                if coordinator.subtitleTracks.count > 1 { tab(.subtitles, L10n.subtitles) }
                if coordinator.chapters.count > 1 { tab(.chapters, L10n.chapters) }
                Spacer()
            }
            .focusSection()
            Group {
                switch panel {
                case .info: infoTab
                case .audio: trackList(coordinator.audioTracks, selected: coordinator.selectedAudioIndex) { coordinator.selectAudio($0) }
                case .subtitles: subtitlesTab
                case .chapters: chaptersTab
                }
            }
            .focusSection()
            Spacer()
        }
        .padding(.horizontal, 90)
        .padding(.top, 60)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(LinearGradient(colors: [.black.opacity(0.92), .black.opacity(0.7), .clear], startPoint: .top, endPoint: .bottom).ignoresSafeArea())
        .focusScope(focusNamespace)
        .onExitCommand(perform: close)
        .onPlayPauseCommand { coordinator.togglePlayPause() }
        .onAppear {
            // The remote-input view held focus until now; move it onto the tab bar explicitly.
            DispatchQueue.main.async { focusedTab = panel }
        }
    }

    private func tab(_ target: OverlayModel.Panel, _ title: String) -> some View {
        Button(title) { panel = target }
            .buttonStyle(PillButtonStyle(prominent: panel == target))
            .focused($focusedTab, equals: target)
            .prefersDefaultFocus(target == panel, in: focusNamespace)
    }

    private var infoTab: some View {
        HStack(alignment: .top, spacing: Spacing.xl) {
            VStack(alignment: .leading, spacing: Spacing.s) {
                Text(coordinator.item.isEpisode ? coordinator.item.episodeSubtitle : coordinator.item.metaLine)
                    .font(Typography.meta).foregroundStyle(Color.foyerSecondaryText)
                Text(coordinator.item.displayTitle).font(Typography.screenTitle)
                if let overview = coordinator.item.overview {
                    Text(overview).font(Typography.body).foregroundStyle(Color.foyerSecondaryText).lineLimit(6)
                }
            }
            .frame(maxWidth: 1000, alignment: .leading)
            if environment.preferences.debugModeEnabled, let decision = coordinator.decision {
                VStack(alignment: .leading, spacing: 4) {
                    Text(decision.route.displayName).font(Typography.bodyEmphasis)
                    ForEach(decision.reasons, id: \.self) { Text("• " + $0).font(Typography.caption).foregroundStyle(Color.foyerSecondaryText) }
                    ForEach(coordinator.statistics.lines, id: \.self) { Text($0).font(Typography.mono).foregroundStyle(Color.foyerTertiaryText) }
                }
                .frame(maxWidth: 700, alignment: .leading)
            }
        }
    }

    private func trackList(_ tracks: [PlayerTrack], selected: Int?, action: @escaping (PlayerTrack) -> Void) -> some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: Spacing.xs) {
                ForEach(tracks) { track in
                    Button {
                        action(track)
                    } label: {
                        HStack {
                            Image(systemName: track.streamIndex == selected ? "checkmark.circle.fill" : "circle")
                            VStack(alignment: .leading, spacing: 2) {
                                Text(track.title).font(Typography.body)
                                if let detail = track.detail { Text(detail).font(Typography.caption).foregroundStyle(.secondary) }
                            }
                            Spacer()
                        }
                    }
                    .buttonStyle(ListRowButtonStyle())
                    .accessibilityAddTraits(track.streamIndex == selected ? .isSelected : [])
                }
            }
            .frame(maxWidth: 900, alignment: .leading)
        }
        .frame(maxHeight: 620)
    }

    private var subtitlesTab: some View {
        HStack(alignment: .top, spacing: Spacing.xl) {
            trackList(coordinator.subtitleTracks, selected: coordinator.selectedSubtitleIndex) { coordinator.selectSubtitle($0) }
            VStack(alignment: .leading, spacing: Spacing.s) {
                Text(L10n.subtitleDelay).font(Typography.meta).foregroundStyle(Color.foyerSecondaryText)
                HStack(spacing: Spacing.s) {
                    Button { coordinator.subtitleDelay -= 0.1 } label: { Image(systemName: "minus") }.buttonStyle(IconButtonStyle())
                    Text(String(format: "%+.1f s", coordinator.subtitleDelay)).font(Typography.body.monospacedDigit()).frame(width: 160)
                    Button { coordinator.subtitleDelay += 0.1 } label: { Image(systemName: "plus") }.buttonStyle(IconButtonStyle())
                }
                Text(L10n.audioDelay).font(Typography.meta).foregroundStyle(Color.foyerSecondaryText).padding(.top, Spacing.m)
                HStack(spacing: Spacing.s) {
                    Button { coordinator.audioDelay -= 0.05 } label: { Image(systemName: "minus") }.buttonStyle(IconButtonStyle())
                    Text(String(format: "%+.2f s", coordinator.audioDelay)).font(Typography.body.monospacedDigit()).frame(width: 160)
                    Button { coordinator.audioDelay += 0.05 } label: { Image(systemName: "plus") }.buttonStyle(IconButtonStyle())
                }
            }
        }
    }

    private var chaptersTab: some View {
        ScrollView(.horizontal) {
            LazyHStack(alignment: .top, spacing: Spacing.m) {
                ForEach(Array(coordinator.chapters.enumerated()), id: \.offset) { index, chapter in
                    Button {
                        coordinator.seek(to: chapter.start)
                        close()
                    } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            RemoteImage(url: chapter.imageURL, targetSize: CardSize.landscape, systemImage: "film")
                                .frame(width: 320, height: 180)
                                .clipShape(RoundedRectangle(cornerRadius: 10))
                            Text(chapter.title).font(Typography.cardSubtitle).lineLimit(1)
                            Text(chapter.start.clockString).font(Typography.caption).foregroundStyle(.secondary)
                        }
                        .frame(width: 320)
                    }
                    .buttonStyle(CardButtonStyleFoyer())
                    .accessibilityLabel("\(index + 1). \(chapter.title), \(chapter.start.clockString)")
                }
            }
            .padding(.vertical, Spacing.m)
        }
        .scrollClipDisabled()
    }
}
