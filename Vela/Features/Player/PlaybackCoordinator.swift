import Foundation
import Observation
import UIKit
import VelaFoundation
import JellyfinKit
import PlaybackDecision

/// Drives one player screen: fetches playback info, decides the route, owns the engine,
/// keeps the server informed and reacts to failures with a fallback chain.
/// The UI observes this object and never learns which engine is rendering.
@MainActor
@Observable
final class PlaybackCoordinator: Identifiable {
    enum Phase: Equatable {
        case preparing
        case ready
        case failed(VelaError)
        case finished
    }

    // MARK: Inputs
    let id = UUID()
    private let client: JellyfinClient
    private let preferences: Preferences
    private let images: ImagePipeline
    private let decisionEngine: PlaybackDecisionEngine
    private let capabilities: DeviceCapabilities
    var onClose: (@MainActor () -> Void)?
    /// Overridable for tests; production builds create the real engines.
    var engineFactory: (@MainActor (PlaybackEngineKind) -> any PlaybackEngine)?

    // MARK: Observable state
    private(set) var item: BaseItem
    private(set) var phase: Phase = .preparing
    private(set) var engineState: PlaybackEngineState = .idle
    private(set) var currentTime: TimeInterval = 0
    private(set) var duration: TimeInterval = 0
    private(set) var isBuffering = false
    private(set) var decision: PlaybackDecision?
    private(set) var audioTracks: [PlayerTrack] = []
    private(set) var subtitleTracks: [PlayerTrack] = []
    private(set) var selectedAudioIndex: Int?
    private(set) var selectedSubtitleIndex: Int?
    private(set) var skipPrompt: SkipPrompt = .none
    private(set) var nextEpisode: BaseItem?
    private(set) var countdownSeconds: Int?
    private(set) var chapters: [(title: String, start: TimeInterval, imageURL: URL?)] = []
    private(set) var statistics = PlaybackStatistics()
    private(set) var engineGeneration = 0
    private(set) var subtitleTimeline: SubtitleTimeline?
    private(set) var isSwitchingEngine = false
    var subtitleDelay: TimeInterval = 0 { didSet { engine?.subtitleDelay = subtitleDelay } }
    var audioDelay: TimeInterval = 0 { didSet { engine?.audioDelay = audioDelay } }

    var isPlaying: Bool { engineState == .playing }
    var engineKind: PlaybackEngineKind? { engine?.kind }
    var trickplay: TrickplayGeometry?
    var trickplayTileURL: ((Int) -> URL?)?

    // MARK: Private
    private(set) var engine: (any PlaybackEngine)?
    private var mediaSourceId: String?
    private var start: PlaybackStart
    private let reporter: PlaybackSessionReporter
    private var segments: [MediaSegment] = []
    private var dismissedSegments: Set<String> = []
    private var serverSource: MediaSource?
    private var playSessionId: String?
    private var fallbackRoutes: [PlaybackRoute] = []
    private var attemptedRoutes: Set<PlaybackRoute> = []
    private var countdownCancelled = false
    private var countdownStart: TimeInterval?
    private var nextEpisodeButtonStart: TimeInterval?
    private static let nextEpisodeButtonLead: TimeInterval = 30
    private var startTask: Task<Void, Never>?
    private var didReportStart = false
    private var externalSubtitles: [ExternalSubtitle] = []
    /// PGS/VobSub decoded from the original file for the native engine (`SubtitleHandling.bitmapOverlay`).
    private var bitmapSubtitle: EmbeddedSubtitleSource?
    /// Overlay to start once the engine plays: the server reads the same file for its remux and gets the disk first.
    private var pendingBitmapOverlay: (streamIndex: Int, source: MediaSource)?
    /// Embedded text track read from the original file (native engine), started like the bitmap overlay.
    private var textSubtitle: EmbeddedSubtitleSource?
    private var pendingTextSubtitle: (streamIndex: Int, source: MediaSource)?
    private var textCueVersion = -1
    private var subtitleLoadTask: Task<Void, Never>?
    private let skipPolicy = SkipSegmentPolicy()
    private let countdownPolicy = NextEpisodeCountdownPolicy()
    private var closed = false
    private var loadedFullItem = false
    /// Start position handed to the current engine; used when a fallback happens before playback began.
    private var requestedStartPosition: TimeInterval = 0
    /// Seek target until the engine confirms it: keeps stale pre-seek time updates from overwriting
    /// `currentTime`, and lets a fallback after a failed seek resume at the target, not before it.
    private var pendingSeek: (target: TimeInterval, issued: Date)?
    /// Set while a next/previous item or a route change is in flight; blocks re-entrant transitions.
    private var transitioning = false

    init(item: BaseItem, mediaSourceId: String?, start: PlaybackStart, client: JellyfinClient, preferences: Preferences,
         capabilities: DeviceCapabilities, images: ImagePipeline) {
        self.item = item
        self.mediaSourceId = mediaSourceId
        self.start = start
        self.client = client
        self.preferences = preferences
        self.capabilities = capabilities
        self.images = images
        self.decisionEngine = PlaybackDecisionEngine(capabilities: capabilities, preferences: preferences.playback)
        self.reporter = PlaybackSessionReporter(client: client)
        reporter.positionProvider = { [weak self] in
            guard let self else { return (0, true) }
            return (self.currentTime, !self.isPlaying)
        }
    }

    // MARK: Lifecycle

    /// Stream indices requested by whoever started playback (remote control); `-1` subtitle = off.
    var preferredAudioStreamIndex: Int?
    var preferredSubtitleStreamIndex: Int?

    func begin() {
        guard startTask == nil else { return }
        startTask = Task { await prepare(startPosition: nil, overrideAudio: preferredAudioStreamIndex, overrideSubtitle: preferredSubtitleStreamIndex) }
    }

    func close() {
        guard !closed else { return }
        closed = true
        startTask?.cancel()
        subtitleLoadTask?.cancel()
        let position = currentTime
        stopBitmapOverlay()
        stopTextSubtitle()
        cancelAbandonedServerStream()
        let engine = self.engine
        self.engine = nil
        PlaybackDecisionJournal.shared.updateStatistics(statistics.lines.joined(separator: "\n"))
        engine?.stop()
        DisplayCriteriaController.reset()
        UIApplication.shared.isIdleTimerDisabled = false
        rememberAudioLanguage()
        let reporter = self.reporter
        Task {
            await reporter.stop(position: position)
        }
        phase = .finished
        onClose?()
    }

    private func rememberAudioLanguage() {
        guard item.isEpisode, let seriesId = item.seriesId,
              let track = audioTracks.first(where: { $0.streamIndex == selectedAudioIndex }), let language = track.language else { return }
        preferences.rememberAudioLanguage(language, forSeries: seriesId)
    }

    // MARK: Preparation

    /// Full preparation: item → decision → PlaybackInfo → engine.
    private func prepare(startPosition: TimeInterval?, overrideAudio: Int?, overrideSubtitle: Int?, forcedRoute: PlaybackRoute? = nil) async {
        phase = .preparing
        do {
            // 1. Make sure we have media sources, chapters and trickplay info (one full fetch per item).
            if !loadedFullItem {
                item = try await client.item(id: item.id)
                loadedFullItem = true
            }
            guard let source = item.mediaSource(id: mediaSourceId) else {
                throw VelaError(.videoLoadFailed, detail: "Item \(item.id) has no media sources")
            }
            mediaSourceId = source.id

            // 2. Default tracks.
            let remembered = item.seriesId.flatMap { preferences.rememberedAudioLanguages[$0] }
            let selection = TrackSelector.select(streams: source.streams, preferences: preferences.languages, rememberedAudioLanguage: remembered,
                                                 rememberedSubtitle: preferences.subtitleChoice(itemId: item.id, seriesId: item.seriesId))
            let audioIndex = overrideAudio ?? selectedAudioIndex ?? selection.audioStreamIndex
            let subtitleIndex: Int? = overrideSubtitle == nil && selectedSubtitleIndex == nil ? selection.subtitleStreamIndex : (overrideSubtitle == -1 ? nil : (overrideSubtitle ?? selectedSubtitleIndex))
            Log.info(.playback, "Track selection: \(selection.reasons.joined(separator: "; "))")

            // 3. Local decision.
            var decision = decisionEngine.decide(source: source, audioStreamIndex: audioIndex, subtitleStreamIndex: subtitleIndex)
            if let forcedRoute {
                decision = decision.rerouted(to: forcedRoute, engineBuilder: DeviceProfileBuilder(capabilities: capabilities, preferences: preferences.playback))
            }
            try Task.checkCancellation()

            // 4. Ask the server.
            let resolvedStart = startPosition ?? initialStartPosition()
            requestedStartPosition = resolvedStart
            let request = PlaybackInfoRequest(userId: client.userId, mediaSourceId: source.id, deviceProfile: decision.deviceProfile,
                                              maxStreamingBitrate: preferences.playback.maxStreamingBitrate ?? DeviceProfileBuilder.unlimitedBitrate,
                                              startTimeTicks: JellyfinTicks.ticks(seconds: resolvedStart),
                                              audioStreamIndex: decision.audioStreamIndex,
                                              // -1 keeps the server from burning a bitmap track in; Vela draws it itself.
                                              subtitleStreamIndex: decision.subtitleHandling == .bitmapOverlay ? -1 : decision.subtitleStreamIndex,
                                              enableDirectPlay: decision.enableDirectPlay && decision.route.method == .directPlay,
                                              enableDirectStream: decision.enableDirectStream, enableTranscoding: decision.enableTranscoding)
            let response = try await client.playbackInfo(itemId: item.id, request: request)
            if let code = response.errorCode {
                throw VelaError(.formatUnsupported, detail: "PlaybackInfo error \(code)")
            }
            guard let server = response.mediaSources.first(where: { $0.id == source.id }) ?? response.mediaSources.first else {
                throw VelaError(.videoLoadFailed, detail: "PlaybackInfo returned no media sources")
            }
            decision = decisionEngine.reconcile(decision, with: server)
            self.serverSource = server
            self.playSessionId = response.playSessionId
            self.decision = decision
            try Task.checkCancellation()

            // 5. Stream URL.
            let url: URL
            switch decision.route {
            case .nativeDirectPlay, .advancedDirectPlay:
                guard let direct = client.directStreamURL(itemId: item.id, mediaSourceId: server.id, playSessionId: response.playSessionId,
                                                          eTag: server.eTag, container: server.container) else {
                    throw VelaError(.videoLoadFailed, detail: "Cannot build stream URL")
                }
                url = direct
            case .directStream, .transcode:
                guard let path = server.transcodingUrl, let transcoding = client.transcodingURL(path: path) else {
                    // Server said it can direct play after all.
                    guard let direct = client.directStreamURL(itemId: item.id, mediaSourceId: server.id, playSessionId: response.playSessionId,
                                                              eTag: server.eTag, container: server.container) else {
                        throw VelaError(.videoLoadFailed, detail: "No transcoding URL and no direct URL")
                    }
                    url = direct
                    decision.route = .nativeDirectPlay
                    decision.reasons.append("server offered the original file instead of a transcoding URL")
                    self.decision = decision
                    break
                }
                url = transcoding
            }

            // 5b. Server streams: fetch the first segment before the player does. Jellyfin needs a few seconds
            // (or more on a slow disk) to seek and produce it; AVPlayer gives up after ~10 s, we wait longer.
            if decision.route == .directStream || decision.route == .transcode, url.path.lowercased().hasSuffix(".m3u8") {
                await HLSWarmup.prefetchSegment(of: url, at: resolvedStart)
                try Task.checkCancellation()
            }

            // 6. Tracks and subtitles.
            buildTracks(from: server, decision: decision)
            selectedAudioIndex = decision.audioStreamIndex
            selectedSubtitleIndex = decision.subtitleStreamIndex

            PlaybackDecisionJournal.shared.record(title: item.displayTitle, decision: decision, mediaSummary: mediaSummary(server))
            Log.notice(.playback, "Decision for '\(item.displayTitle)':\n\(decision.summary)")
            Log.info(.playback, "Stream URL: \(url.absoluteString)")

            // 7. Engine.
            fallbackRoutes = fallbackChain(after: decision.route, source: server, decision: decision)
            attemptedRoutes.insert(decision.route)
            let engine = makeEngine(for: decision.engine)
            let load = EngineLoadRequest(
                itemId: item.id,
                mediaSource: server,
                url: url,
                route: decision.route,
                startPosition: resolvedStart,
                audioStreamIndex: decision.audioStreamIndex,
                subtitleStreamIndex: decision.subtitleStreamIndex,
                externalSubtitles: externalSubtitles,
                fontURLs: fontURLs(server),
                title: item.isEpisode ? (item.name ?? "") : item.displayTitle,
                subtitle: item.isEpisode ? item.episodeSubtitle : item.yearText,
                artworkURL: ItemImages(client: client).poster(item, width: 600),
                chapters: chapters,
                frameRate: server.videoStream?.frameRate,
                isHDR: server.videoStream?.isHDR ?? false
            )
            engine.subtitleDelay = subtitleDelay
            engine.audioDelay = audioDelay
            engine.load(load)
            stopBitmapOverlay()
            if decision.subtitleHandling == .bitmapOverlay, let index = decision.subtitleStreamIndex {
                pendingBitmapOverlay = (index, server)
            } else {
                pendingBitmapOverlay = nil
            }
            engine.updateTrackMenus(audio: audioTracks, subtitles: subtitleTracks, selectedAudio: selectedAudioIndex, selectedSubtitle: selectedSubtitleIndex)
            phase = .ready
            isSwitchingEngine = false
            transitioning = false
            UIApplication.shared.isIdleTimerDisabled = true

            // 8. Subtitles rendered by Vela (native engine, text tracks).
            refreshSubtitleOverlay()

            // 9. Side information, off the critical path.
            Task { await loadSegments() }
            Task { await loadNextEpisode() }
            setupTrickplay(server)
            engine.setTrickplay(trickplay, tileURL: trickplayTileURL)
        } catch is CancellationError {
        } catch {
            let wrapped = VelaError.wrap(error)
            Log.error(.playback, "Preparation failed: \(wrapped)")
            isSwitchingEngine = false
            transitioning = false
            phase = .failed(wrapped.kind == .unknown ? VelaError(.videoLoadFailed, detail: wrapped.detail) : wrapped)
        }
    }

    private func initialStartPosition() -> TimeInterval {
        switch start {
        case .automatic: return ResumePolicy.resumePosition(for: item) ?? 0
        case .beginning: return 0
        case .at(let time): return time
        }
    }

    private func makeEngine(for kind: PlaybackEngineKind) -> any PlaybackEngine {
        engine?.stop()
        let created: any PlaybackEngine
        if let engineFactory {
            created = engineFactory(kind)
        } else {
            switch kind {
            case .advanced where AdvancedPlaybackEngine.isAvailable:
                created = AdvancedPlaybackEngine(images: images)
            default:
                created = NativePlaybackEngine()
            }
        }
        created.delegate = self
        engine = created
        engineGeneration += 1
        return created
    }

    private func buildTracks(from source: MediaSource, decision: PlaybackDecision) {
        audioTracks = source.audioStreams.map(PlayerTrack.init(stream:))
        var subs: [PlayerTrack] = [.subtitlesOff]
        externalSubtitles = []
        for stream in source.subtitleStreams {
            subs.append(PlayerTrack(stream: stream))
            if stream.isTextSubtitle {
                let format = SubtitleFormat(codec: stream.normalizedCodec)
                if let url = client.subtitleURL(itemId: item.id, mediaSourceId: source.id, streamIndex: stream.index,
                                                format: format.externalFileExtension, deliveryUrl: stream.deliveryUrl) {
                    let hint: SubtitleTextFormat? = format.isASS ? .ass : (format.codec.contains("vtt") ? .webvtt : .srt)
                    externalSubtitles.append(ExternalSubtitle(streamIndex: stream.index, url: url, format: hint, language: stream.language,
                                                              title: PlayerTrack(stream: stream).title))
                }
            }
        }
        subtitleTracks = subs
        chapters = (item.chapters ?? []).enumerated().map { index, chapter in
            (title: chapter.name ?? "\(index + 1)", start: chapter.start, imageURL: ItemImages(client: client).chapter(item, index: index, tag: chapter.imageTag))
        }
    }

    private func fontURLs(_ source: MediaSource) -> [URL] {
        (source.mediaAttachments ?? []).filter { $0.isFont }.compactMap { attachment in
            guard let index = attachment.index else { return nil }
            if let delivery = attachment.deliveryUrl { return client.mediaURL(for: delivery) }
            return client.attachmentURL(itemId: item.id, mediaSourceId: source.id, attachmentIndex: index)
        }
    }

    private func setupTrickplay(_ source: MediaSource) {
        guard let variants = item.trickplay?[source.id] ?? item.trickplay?.values.first,
              let best = TrickplayGeometry.bestVariant(from: variants, preferredWidth: 320) else {
            trickplay = nil
            trickplayTileURL = nil
            return
        }
        trickplay = TrickplayGeometry(info: best.info, width: best.width)
        let itemId = item.id
        let sourceId = source.id
        let width = best.width
        let client = self.client
        trickplayTileURL = { index in client.trickplayTileURL(itemId: itemId, width: width, tileIndex: index, mediaSourceId: sourceId) }
    }

    private func mediaSummary(_ source: MediaSource) -> String {
        var lines: [String] = []
        lines.append("Container: \(source.container ?? "?")")
        if let v = source.videoStream {
            lines.append("Video: \(v.technicalLabel) \(v.width ?? 0)×\(v.height ?? 0) \(v.frameRate.map { String(format: "%.3f fps", $0) } ?? "") \(v.profile ?? "") \(v.codecTag ?? "")")
        }
        for a in source.audioStreams { lines.append("Audio #\(a.index): \(a.technicalLabel) \(a.language ?? "")") }
        for s in source.subtitleStreams { lines.append("Subtitle #\(s.index): \(s.technicalLabel) \(s.language ?? "") \(s.isForced == true ? "forced" : "")") }
        if let bitrate = source.bitrate { lines.append("Bitrate: \(bitrate / 1_000_000) Mbit/s") }
        return lines.joined(separator: "\n")
    }

    // MARK: Fallbacks

    private func fallbackChain(after route: PlaybackRoute, source: MediaSource, decision: PlaybackDecision) -> [PlaybackRoute] {
        var chain: [PlaybackRoute] = []
        let video = source.videoStream
        let audio = source.stream(index: decision.audioStreamIndex) ?? source.audioStreams.first
        let subtitle = source.stream(index: decision.subtitleStreamIndex)
        let native = NativeCapability.check(source: source, video: video, audio: audio, subtitle: subtitle, capabilities: capabilities)
        let advanced = AdvancedPlaybackEngine.isAvailable && preferences.playback.advancedEngineMode != .never
            ? AdvancedCapability.check(source: source, video: video, audio: audio, subtitle: subtitle, capabilities: capabilities) : .unavailable
        switch route {
        case .advancedDirectPlay:
            if native.canDirectPlay { chain.append(.nativeDirectPlay) }
        case .nativeDirectPlay:
            if advanced.canDirectPlay { chain.append(.advancedDirectPlay) }
        default:
            break
        }
        if preferences.playback.directPlayMode != .forced {
            if route != .directStream, source.supportsDirectStream ?? true, NativeCapability.videoCompatibleAfterRemux(video, caps: capabilities) {
                chain.append(.directStream)
            }
            // A server stream that failed (slow remux, broken segments) is better replaced by local playback
            // than by another server stream; the picture may lose HDR, the film keeps playing.
            if route == .directStream || route == .transcode, advanced.canDirectPlay, serverAllowsDirectPlay(source) {
                chain.append(.advancedDirectPlay)
            }
            if route != .transcode, source.supportsTranscoding ?? true {
                chain.append(.transcode)
            }
        }
        return chain.filter { !attemptedRoutes.contains($0) }
    }

    private func serverAllowsDirectPlay(_ source: MediaSource) -> Bool { source.supportsDirectPlay ?? true }

    /// Tells the server to drop an HLS job the player abandoned before it reported a start (the reporter only
    /// cancels jobs of started sessions). Orphaned ffmpeg jobs compete with the retry for the same file.
    private func cancelAbandonedServerStream() {
        guard !didReportStart, let decision, decision.route == .directStream || decision.route == .transcode,
              let playSessionId else { return }
        let client = self.client
        Task { try? await client.stopTranscoding(playSessionId: playSessionId) }
        Log.info(.jellyfin, "Cancelled the abandoned server stream \(playSessionId.prefix(8))")
    }

    private func attemptFallback(after error: VelaError) {
        guard !transitioning else { return }
        guard let next = fallbackRoutes.first(where: { !attemptedRoutes.contains($0) }) else {
            isSwitchingEngine = false
            phase = .failed(error)
            Task { await reporter.stop(position: currentTime, failed: true) }
            return
        }
        Log.warning(.playback, "Route \(decision?.route.rawValue ?? "?") failed (\(error)); trying \(next.rawValue)")
        cancelAbandonedServerStream()
        // If the engine never produced a frame, resume where the user asked to start, not at 0;
        // if it died during a seek, resume at the seek target.
        let position = pendingSeek?.target ?? (didReportStart ? max(currentTime, 0) : max(currentTime, requestedStartPosition))
        pendingSeek = nil
        isSwitchingEngine = true
        transitioning = true
        Task {
            await reporter.stop(position: position, failed: false)
            didReportStart = false
            await prepare(startPosition: position, overrideAudio: selectedAudioIndex, overrideSubtitle: selectedSubtitleIndex ?? -1, forcedRoute: next)
        }
    }

    // MARK: Segments & next episode

    private func loadSegments() async {
        do {
            let server = try await client.mediaSegments(itemId: item.id)
            // Episodes without server segments (Intro Skipper) still get intro/credits from chapter names.
            let chapters = item.isEpisode
                ? ChapterSegments.segments(chapters: (item.chapters ?? []).map { ($0.name, $0.start) }, duration: duration > 0 ? duration : item.runtime ?? 0)
                : []
            segments = ChapterSegments.merge(server: server, chapters: chapters)
            if !segments.isEmpty {
                Log.info(.playback, "Segments: " + segments.map { "\($0.type.rawValue) \($0.start.clockString)–\($0.end.clockString)" }.joined(separator: ", "))
            }
            updateCountdownStart()
        } catch {
            Log.notice(.playback, "Segments unavailable: \(VelaError.wrap(error))")
        }
    }

    private func loadNextEpisode() async {
        guard item.isEpisode else { return }
        nextEpisode = await NextEpisodeResolver.next(after: item, client: client)
        updateCountdownStart()
        pushNextEpisodeToEngine()
    }

    private func updateCountdownStart() {
        // The "Next episode" button of the system player: from the credits, or the last 30 s when they are unknown.
        nextEpisodeButtonStart = nextEpisode == nil || duration <= 60 ? nil
            : (segments.first { $0.type == .outro }?.start ?? max(0, duration - Self.nextEpisodeButtonLead))
        guard nextEpisode != nil, preferences.autoPlayNextEpisode, duration > 0 else {
            countdownStart = nil
            return
        }
        countdownStart = countdownPolicy.countdownStart(mediaDuration: duration, outro: segments.first { $0.type == .outro })
        Log.debug(.playback, "Next-episode countdown starts at \(countdownStart?.clockString ?? "-") (duration \(duration.clockString), outro \(segments.first { $0.type == .outro }?.start.clockString ?? "none"))")
    }

    private func pushNextEpisodeToEngine() {
        let credits = segments.first { $0.type == .outro }?.start
        engine?.updateNextEpisode(nextEpisode, artworkURL: nextEpisode.flatMap { ItemImages(client: client).landscape($0, width: 600) },
                                  creditsStart: credits ?? countdownStart, autoplay: preferences.autoPlayNextEpisode)
    }

    // MARK: Time-driven UI state

    private func tick(time: TimeInterval) {
        var prompt = skipPolicy.prompt(at: time, segments: segments, mediaDuration: duration, dismissed: dismissedSegments, hasNextEpisode: nextEpisode != nil)
        // The advanced engine shows its own countdown card; the system player gets a button for the next episode.
        if case .none = prompt, engine?.kind == .native, nextEpisode != nil, let start = nextEpisodeButtonStart,
           time >= start, duration - time > 1, !dismissedSegments.contains("next-episode") {
            prompt = .nextEpisode(creditsStart: start, mediaEnd: duration)
        }
        if prompt != skipPrompt {
            skipPrompt = prompt
            engine?.updateSkipAction(title: skipTitle(prompt))
        }
        if engine?.kind == .advanced, let start = countdownStart, let next = nextEpisode, !countdownCancelled, duration > 0 {
            if time >= start {
                let remaining = Int((duration - time).rounded(.up))
                let seconds = max(0, min(countdownPolicy.countdownSeconds, remaining))
                if countdownSeconds != seconds {
                    if countdownSeconds == nil { Log.info(.playback, "Next-episode countdown visible (\(seconds) s)") }
                    countdownSeconds = seconds
                }
                if seconds == 0 { playNext(next) }
            } else if countdownSeconds != nil {
                countdownSeconds = nil
            }
        }
    }

    private func skipTitle(_ prompt: SkipPrompt) -> String? {
        switch prompt {
        case .none: nil
        case .skipIntro: L10n.skipIntro
        case .skipRecap: L10n.skipRecap
        case .skipCommercial: L10n.skipAd
        case .nextEpisode: nextEpisode != nil ? L10n.nextEpisode : nil
        }
    }

    // MARK: User actions

    func togglePlayPause() {
        guard let engine else { return }
        if engine.isPlaying { engine.pause() } else { engine.play() }
    }

    func play() { engine?.play() }
    func pause() { engine?.pause() }

    /// The overlay tells the engine when it covers the lower part of the picture.
    func setControlsVisible(_ visible: Bool) { engine?.setControlsVisible(visible) }

    func seek(to time: TimeInterval) {
        let clamped = max(0, min(time, duration > 0 ? duration - 0.5 : time))
        pendingSeek = (clamped, Date())
        engine?.seek(to: clamped)
        bitmapSubtitle?.seek(to: clamped)
        textSubtitle?.seek(to: clamped)
        currentTime = clamped
    }

    func seek(by delta: TimeInterval) {
        seek(to: currentTime + delta)
    }

    func performSkip() {
        switch skipPrompt {
        case .none:
            return
        case let .skipIntro(to), let .skipRecap(to), let .skipCommercial(to):
            if let segment = segments.first(where: { $0.contains(currentTime) }) { dismissedSegments.insert(segment.id) }
            seek(to: to)
        case .nextEpisode:
            if let next = nextEpisode { playNext(next) } else if let end = skipPrompt.target { seek(to: end) }
        }
    }

    func dismissSkipPrompt() {
        if let segment = segments.first(where: { $0.contains(currentTime) }) { dismissedSegments.insert(segment.id) }
        skipPrompt = .none
        engine?.updateSkipAction(title: nil)
    }

    func cancelCountdown() {
        countdownCancelled = true
        countdownSeconds = nil
    }

    func playNext(_ next: BaseItem? = nil) {
        guard !transitioning, let next = next ?? nextEpisode else { return }
        transitioning = true
        Log.info(.playback, "Playing next episode \(next.episodeLabel ?? next.id)")
        let position = currentTime
        rememberAudioLanguage()
        engine?.pause()
        Task {
            await reporter.stop(position: position)
            resetForNewItem(next)
            await prepare(startPosition: nil, overrideAudio: nil, overrideSubtitle: nil)
        }
    }

    func playPrevious() {
        guard !transitioning else { return }
        transitioning = true
        Task {
            guard let previous = await NextEpisodeResolver.previous(before: item, client: client) else {
                transitioning = false
                return
            }
            let position = currentTime
            await reporter.stop(position: position)
            resetForNewItem(previous)
            await prepare(startPosition: nil, overrideAudio: nil, overrideSubtitle: nil)
        }
    }

    private func resetForNewItem(_ next: BaseItem) {
        item = next
        loadedFullItem = false
        mediaSourceId = nil
        start = .automatic
        segments = []
        dismissedSegments = []
        nextEpisode = nil
        countdownSeconds = nil
        countdownStart = nil
        nextEpisodeButtonStart = nil
        countdownCancelled = false
        attemptedRoutes = []
        fallbackRoutes = []
        didReportStart = false
        pendingSeek = nil
        currentTime = 0
        duration = 0
        skipPrompt = .none
        subtitleTimeline = nil
        // Keep language choices, but resolve indices fresh for the new file.
        selectedAudioIndex = nil
        selectedSubtitleIndex = nil
        stopBitmapOverlay()
        stopTextSubtitle()
    }

    func selectAudio(_ track: PlayerTrack) {
        guard !transitioning, let index = track.streamIndex, index != selectedAudioIndex else { return }
        if let engine, engine.selectAudio(streamIndex: index) {
            selectedAudioIndex = index
            reporter.updateTracks(audio: selectedAudioIndex, subtitle: selectedSubtitleIndex)
            engine.updateTrackMenus(audio: audioTracks, subtitles: subtitleTracks, selectedAudio: selectedAudioIndex, selectedSubtitle: selectedSubtitleIndex)
            Log.info(.audio, "Switched audio to #\(index) in engine")
        } else {
            reload(audio: index, subtitle: selectedSubtitleIndex)
        }
    }

    func selectSubtitle(_ track: PlayerTrack) {
        let index = track.streamIndex
        guard !transitioning, index != selectedSubtitleIndex else { return }
        guard let engine, let source = serverSource else { return }
        preferences.rememberSubtitle(index == nil ? .off : .track(language: track.language, forced: track.isForced, sdh: track.isSDH),
                                     itemId: item.id, seriesId: item.seriesId)
        let stream = source.stream(index: index)
        let isBitmap = stream?.isBitmapSubtitle ?? false
        if isBitmap, engine.kind == .native, capabilities.bitmapOverlayAvailable, let index {
            // Decoded from the original file and drawn over AVPlayer; no reload, the HDR remux stays.
            startBitmapOverlay(streamIndex: index, source: source, at: currentTime)
            selectedSubtitleIndex = index
            reporter.updateTracks(audio: selectedAudioIndex, subtitle: selectedSubtitleIndex)
            engine.updateTrackMenus(audio: audioTracks, subtitles: subtitleTracks, selectedAudio: selectedAudioIndex, selectedSubtitle: selectedSubtitleIndex)
            Log.info(.subtitle, "Switched subtitles to #\(index) (bitmap overlay)")
            return
        }
        if bitmapSubtitle != nil { stopBitmapOverlay() }
        let needsOtherEngine = isBitmap && engine.kind == .native
        if !needsOtherEngine, engine.selectSubtitle(streamIndex: index) {
            selectedSubtitleIndex = index
            reporter.updateTracks(audio: selectedAudioIndex, subtitle: selectedSubtitleIndex)
            engine.updateTrackMenus(audio: audioTracks, subtitles: subtitleTracks, selectedAudio: selectedAudioIndex, selectedSubtitle: selectedSubtitleIndex)
            refreshSubtitleOverlay()
            Log.info(.subtitle, "Switched subtitles to \(index.map(String.init) ?? "off") in engine")
        } else {
            reload(audio: selectedAudioIndex, subtitle: index)
        }
    }

    /// Re-runs the decision with new track choices (may switch engines or ask the server for a new stream).
    private func reload(audio: Int?, subtitle: Int?) {
        let position = currentTime
        isSwitchingEngine = true
        transitioning = true
        Log.info(.playback, "Reloading at \(position.clockString) for audio #\(audio.map(String.init) ?? "-") / subtitle #\(subtitle.map(String.init) ?? "off")")
        Task {
            reporter.flush()
            await reporter.stop(position: position)
            didReportStart = false
            attemptedRoutes = []
            await prepare(startPosition: position, overrideAudio: audio, overrideSubtitle: subtitle ?? -1)
        }
    }

    /// Progress of the bitmap subtitle overlay (self-test and debug screen): frames decoded so far and a failure text.
    var bitmapSubtitleStatus: (decoded: Int, failure: String?)? {
        guard let bitmapSubtitle else { return nil }
        return (bitmapSubtitle.decodedFrameCount, bitmapSubtitle.failure)
    }

    // MARK: Bitmap subtitle overlay

    private func startBitmapOverlay(streamIndex: Int, source: MediaSource, at time: TimeInterval) {
        stopBitmapOverlay()
        guard let url = client.directStreamURL(itemId: item.id, mediaSourceId: source.id, playSessionId: nil, eTag: source.eTag, container: source.container) else {
            Log.warning(.subtitle, "Bitmap subtitles: no direct URL for the original file")
            return
        }
        let stream = source.stream(index: streamIndex)
        let overlay = EmbeddedSubtitleSource(url: url, streamIndex: streamIndex, language: stream?.language)
        bitmapSubtitle = overlay
        overlay.start(at: time)
        engine?.setBitmapSubtitle(overlay)
        Log.info(.subtitle, "Bitmap subtitles #\(streamIndex) (\(stream?.technicalLabel ?? "?")) decoded from the original file for the system player")
    }

    /// Called when the engine reports the first playing state.
    private func startPendingBitmapOverlay() {
        guard let pending = pendingBitmapOverlay else { return }
        pendingBitmapOverlay = nil
        startBitmapOverlay(streamIndex: pending.streamIndex, source: pending.source, at: currentTime)
    }

    private func stopBitmapOverlay() {
        pendingBitmapOverlay = nil
        guard let bitmapSubtitle else { return }
        bitmapSubtitle.stop()
        self.bitmapSubtitle = nil
        engine?.setBitmapSubtitle(nil)
    }

    private func refreshSubtitleOverlay() {
        subtitleLoadTask?.cancel()
        subtitleTimeline = nil
        stopTextSubtitle()
        guard engine?.kind == .native, let index = selectedSubtitleIndex,
              let external = externalSubtitles.first(where: { $0.streamIndex == index }) else { return }
        // Embedded text tracks: read near the playhead from the original file. Downloading them from Jellyfin makes
        // the server extract every subtitle track from the whole file first (an hour for a 50 GB file on a slow disk).
        if let source = serverSource, source.stream(index: index)?.isExternal != true {
            if engineState == .playing || engineState == .paused {
                startTextSubtitle(streamIndex: index, source: source, at: currentTime)
            } else {
                pendingTextSubtitle = (index, source)
            }
            return
        }
        subtitleLoadTask = Task { [weak self] in
            do {
                let timeline = try await SubtitleLoader.shared.timeline(for: external.url, format: external.format)
                guard !Task.isCancelled else { return }
                self?.subtitleTimeline = timeline
                Log.info(.subtitle, "Loaded \(timeline.cues.count) cues for stream #\(index)")
            } catch {
                Log.warning(.subtitle, "Subtitle load failed: \(VelaError.wrap(error))")
            }
        }
    }

    private func startTextSubtitle(streamIndex: Int, source: MediaSource, at time: TimeInterval) {
        stopTextSubtitle()
        guard let url = client.directStreamURL(itemId: item.id, mediaSourceId: source.id, playSessionId: nil, eTag: source.eTag, container: source.container) else {
            Log.warning(.subtitle, "Embedded subtitles: no direct URL for the original file")
            return
        }
        let reader = EmbeddedSubtitleSource(url: url, streamIndex: streamIndex, language: source.stream(index: streamIndex)?.language)
        textSubtitle = reader
        textCueVersion = -1
        reader.start(at: time)
        Log.info(.subtitle, "Text subtitles #\(streamIndex) read from the original file near the playhead")
    }

    private func startPendingTextSubtitle() {
        guard let pending = pendingTextSubtitle else { return }
        pendingTextSubtitle = nil
        startTextSubtitle(streamIndex: pending.streamIndex, source: pending.source, at: engine?.currentTime ?? currentTime)
    }

    private func stopTextSubtitle() {
        pendingTextSubtitle = nil
        textSubtitle?.stop()
        textSubtitle = nil
    }

    // MARK: App lifecycle

    func appDidEnterBackground() {
        engine?.pause()
        reporter.flush()
        engine?.appDidEnterBackground()
    }

    func appWillResignActive() {
        engine?.pause()
        reporter.flush()
    }

    func appDidBecomeActive() {
        engine?.appWillEnterForeground()
    }
}

// MARK: - Engine delegate

extension PlaybackCoordinator: PlaybackEngineDelegate {
    func engine(_ engine: any PlaybackEngine, didChangeState state: PlaybackEngineState) {
        guard engine === self.engine else { return }
        let previous = engineState
        engineState = state
        isBuffering = state == .buffering || state == .loading
        statistics = engine.statistics
        switch state {
        case .playing:
            startPendingBitmapOverlay()
            startPendingTextSubtitle()
            if !didReportStart, let decision, let source = serverSource {
                didReportStart = true
                reporter.start(context: .init(itemId: item.id, mediaSourceId: source.id, playSessionId: playSessionId,
                                              playMethod: decision.method.jellyfinPlayMethod, audioStreamIndex: selectedAudioIndex,
                                              subtitleStreamIndex: selectedSubtitleIndex, isTranscoding: decision.method != .directPlay),
                               position: engine.currentTime)
                if engine.kind == .advanced {
                    DisplayCriteriaController.apply(frameRate: serverSource?.videoStream?.frameRate)
                }
            } else if previous == .paused {
                reporter.playbackStateChanged(isPaused: false)
            }
            UIApplication.shared.isIdleTimerDisabled = true
        case .paused:
            if previous == .playing { reporter.playbackStateChanged(isPaused: true) }
        case .ended:
            break
        default:
            break
        }
    }

    func engine(_ engine: any PlaybackEngine, didUpdateTime time: TimeInterval, duration: TimeInterval) {
        guard engine === self.engine else { return }
        bitmapSubtitle?.update(playhead: time)
        if let textSubtitle {
            textSubtitle.update(playhead: time)
            if textSubtitle.textCueVersion != textCueVersion {
                textCueVersion = textSubtitle.textCueVersion
                subtitleTimeline = textSubtitle.textTimeline
            }
        }
        if let pending = pendingSeek {
            if abs(time - pending.target) <= 3 || Date().timeIntervalSince(pending.issued) > 15 {
                pendingSeek = nil
            } else {
                return // the player still reports the pre-seek position
            }
        }
        currentTime = time
        if duration > 0, abs(self.duration - duration) > 0.5 {
            self.duration = duration
            updateCountdownStart()
            pushNextEpisodeToEngine()
        }
        statistics = engine.statistics
        tick(time: time)
    }

    func engineDidReachEnd(_ engine: any PlaybackEngine) {
        guard engine === self.engine, !transitioning else { return }
        Log.info(.playback, "Reached end of '\(item.displayTitle)'")
        if let next = nextEpisode, preferences.autoPlayNextEpisode, !countdownCancelled {
            playNext(next)
        } else {
            close()
        }
    }

    func engine(_ engine: any PlaybackEngine, didFail error: VelaError) {
        guard engine === self.engine else { return }
        Log.error(.playback, "Engine \(engine.kind.rawValue) failed: \(error)")
        attemptFallback(after: error)
    }

    func engineDidCompleteSeek(_ engine: any PlaybackEngine) {
        guard engine === self.engine else { return }
        pendingSeek = nil
        reporter.didSeek()
    }

    func engineRequestsNextItem(_ engine: any PlaybackEngine) { playNext() }
    func engineRequestsPreviousItem(_ engine: any PlaybackEngine) { playPrevious() }
    func engineRequestsSkip(_ engine: any PlaybackEngine) { performSkip() }

    func engine(_ engine: any PlaybackEngine, requestsAudioTrack streamIndex: Int) {
        if let track = audioTracks.first(where: { $0.streamIndex == streamIndex }) { selectAudio(track) }
    }

    func engine(_ engine: any PlaybackEngine, requestsSubtitleTrack streamIndex: Int?) {
        if let track = subtitleTracks.first(where: { $0.streamIndex == streamIndex }) { selectSubtitle(track) }
    }
}

extension PlaybackDecision {
    /// Forces a route (used by the fallback chain) and rebuilds the matching device profile.
    func rerouted(to route: PlaybackRoute, engineBuilder: DeviceProfileBuilder) -> PlaybackDecision {
        var copy = self
        copy.route = route
        copy.deviceProfile = engineBuilder.profile(for: route.engine, allowBurnIn: subtitleHandling == .burnIn)
        copy.reasons.append("fallback: previous route failed, trying \(route.displayName)")
        switch route {
        case .nativeDirectPlay, .advancedDirectPlay:
            copy.enableDirectPlay = true
        case .directStream:
            copy.enableDirectPlay = false
            copy.enableDirectStream = true
            copy.enableTranscoding = true
        case .transcode:
            copy.enableDirectPlay = false
            copy.enableDirectStream = false
            copy.enableTranscoding = true
        }
        return copy
    }
}
