import Foundation
import AVFoundation
import AVKit
import UIKit
import SwiftUI
import VelaFoundation
import JellyfinKit
import PlaybackDecision

/// AVFoundation engine hosted in AVPlayerViewController: the system transport bar, info
/// panel, chapter navigation and HDR/Dolby Vision output come for free. Vela adds
/// Jellyfin-aware track menus, skip actions, the next-episode proposal and its own
/// subtitle overlay for external text tracks.
@MainActor
final class NativePlaybackEngine: NSObject, PlaybackEngine {
    let kind: PlaybackEngineKind = .native
    weak var delegate: (any PlaybackEngineDelegate)?
    private(set) var state: PlaybackEngineState = .idle
    private(set) var statistics = PlaybackStatistics(engine: "AVFoundation")

    private let player = AVPlayer()
    private let controller = AVPlayerViewController()
    private var request: EngineLoadRequest?
    private var timeObserver: Any?
    private var observations: [NSKeyValueObservation] = []
    private var notificationTokens: [any NSObjectProtocol] = []
    private var pendingSeek: TimeInterval?
    private var didStartPlaying = false
    private var subtitleOverlay: UIHostingController<NativeSubtitleOverlay>?
    /// PGS/VobSub decoded from the original file by the coordinator; drawn by `BitmapSubtitleView`.
    private(set) var bitmapSubtitle: BitmapSubtitleSource?
    private var skipTitle: String?
    private var audioMenuTracks: [PlayerTrack] = []
    private var subtitleMenuTracks: [PlayerTrack] = []
    private var selectedAudio: Int?
    private var selectedSubtitle: Int?
    private var lastProposalItemId: String?
    private var audibleGroup: AVMediaSelectionGroup?
    private var legibleGroup: AVMediaSelectionGroup?
    /// What the engine itself last selected in AVFoundation's groups. `mediaSelectionDidChangeNotification` fires for
    /// those changes too; only selections that differ from these come from the system's own menus.
    private var appliedAudioOption: AVMediaSelectionOption?
    private var appliedLegibleOption: AVMediaSelectionOption?
    /// Jellyfin index of the subtitle currently rendered by AVFoundation itself (tx3g), if any.
    private var systemRenderedSubtitle: Int?
    /// Subtitle cues for the overlay are provided by the coordinator via this closure.
    var subtitleTimelineProvider: (() -> SubtitleTimeline?)?
    var subtitleScale: Double = 1

    var subtitleDelay: TimeInterval = 0
    var audioDelay: TimeInterval = 0 // Not adjustable in AVFoundation; kept for protocol symmetry.

    var viewController: UIViewController { controller }
    var currentTime: TimeInterval {
        let t = player.currentTime()
        return t.isValid && !t.isIndefinite ? max(0, t.seconds) : 0
    }
    var duration: TimeInterval {
        guard let d = player.currentItem?.duration, d.isValid, !d.isIndefinite else { return 0 }
        return d.seconds
    }
    var isPlaying: Bool { player.timeControlStatus != .paused && state == .playing }

    override init() {
        super.init()
        controller.player = player
        controller.delegate = self
        controller.appliesPreferredDisplayCriteriaAutomatically = true
        controller.allowsPictureInPicturePlayback = false
        controller.playbackControlsIncludeInfoViews = true
        controller.playbackControlsIncludeTransportBar = true
        controller.transportBarIncludesTitleView = true
        controller.skippingBehavior = .default
        player.appliesMediaSelectionCriteriaAutomatically = false
        player.automaticallyWaitsToMinimizeStalling = true
        player.allowsExternalPlayback = false
        player.preventsDisplaySleepDuringVideoPlayback = true
        installSubtitleOverlay()
    }

    // MARK: Loading

    func load(_ request: EngineLoadRequest) {
        teardownItemObservers()
        self.request = request
        didStartPlaying = false
        setState(.loading)

        // Same User-Agent as the HLS warm-up, so AVPlayer picks up the server job the warm-up started.
        let asset = AVURLAsset(url: request.url, options: [AVURLAssetHTTPUserAgentKey: DeviceInfo.httpUserAgent])
        let item = AVPlayerItem(asset: asset)
        item.preferredForwardBufferDuration = 0 // let AVFoundation size the buffer for the bitrate
        item.externalMetadata = metadata(for: request)
        item.navigationMarkerGroups = chapterGroups(for: request)
        observe(item)
        pendingSeek = request.startPosition > 1 ? request.startPosition : nil
        player.replaceCurrentItem(with: item)
        controller.title = request.title
        updateContextualActions()
        rebuildTransportMenus()
        Log.info(.playback, "Native engine loading \(request.isHLS ? "HLS" : "file") from \(request.startPosition.clockString)")
    }

    private func observe(_ item: AVPlayerItem) {
        observations.append(item.observe(\.status, options: [.new]) { [weak self] item, _ in
            Task { @MainActor [weak self] in self?.itemStatusChanged(item) }
        })
        observations.append(item.observe(\.isPlaybackBufferEmpty, options: [.new]) { [weak self] item, _ in
            Task { @MainActor [weak self] in
                guard let self, self.didStartPlaying, item.isPlaybackBufferEmpty, self.player.timeControlStatus != .paused else { return }
                self.setState(.buffering)
            }
        })
        observations.append(player.observe(\.timeControlStatus, options: [.new]) { [weak self] player, _ in
            Task { @MainActor [weak self] in self?.timeControlChanged(player.timeControlStatus) }
        })
        let center = NotificationCenter.default
        notificationTokens.append(center.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.setState(.ended)
                self.delegate?.engineDidReachEnd(self)
            }
        })
        notificationTokens.append(center.addObserver(forName: .AVPlayerItemFailedToPlayToEndTime, object: item, queue: .main) { [weak self] note in
            Task { @MainActor [weak self] in
                let error = note.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? NSError
                Log.error(.playback, "Native engine failed to play to end: \(AVPlayerDiagnostics.describe(error)); \(AVPlayerDiagnostics.describe(item))")
                self?.fail(VelaError(.videoLoadFailed, detail: "Failed to play to end: \(error?.localizedDescription ?? "unknown")"))
            }
        })
        notificationTokens.append(center.addObserver(forName: .AVPlayerItemPlaybackStalled, object: item, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                Log.notice(.playback, "Native playback stalled; waiting for buffer")
                self?.setState(.buffering)
            }
        })
        notificationTokens.append(center.addObserver(forName: AVPlayerItem.mediaSelectionDidChangeNotification, object: item, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.systemMediaSelectionChanged() }
        })
        notificationTokens.append(center.addObserver(forName: .AVPlayerItemNewErrorLogEntry, object: item, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                if let entry = self?.player.currentItem?.errorLog()?.events.last {
                    Log.notice(.network, "AVPlayer error log: \(entry.errorStatusCode) \(entry.errorComment ?? "") \(entry.errorDomain)")
                }
            }
        })
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.5, preferredTimescale: 600), queue: .main) { [weak self] time in
            Task { @MainActor [weak self] in
                guard let self, time.isValid else { return }
                self.updateStatistics()
                self.delegate?.engine(self, didUpdateTime: max(0, time.seconds), duration: self.duration)
            }
        }
    }

    private func teardownItemObservers() {
        observations.forEach { $0.invalidate() }
        observations.removeAll()
        notificationTokens.forEach { NotificationCenter.default.removeObserver($0) }
        notificationTokens.removeAll()
        if let timeObserver {
            player.removeTimeObserver(timeObserver)
            self.timeObserver = nil
        }
    }

    private func itemStatusChanged(_ item: AVPlayerItem) {
        switch item.status {
        case .readyToPlay:
            guard !didStartPlaying else { return }
            didStartPlaying = true
            Task { [weak self] in
                guard let self else { return }
                let asset = item.asset
                self.audibleGroup = try? await asset.loadMediaSelectionGroup(for: .audible)
                self.legibleGroup = try? await asset.loadMediaSelectionGroup(for: .legible)
                self.applyInitialMediaSelection()
                self.rebuildTransportMenus() // the system shows its own audio menu for multi-track assets
            }
            if let seekTo = pendingSeek {
                pendingSeek = nil
                player.seek(to: CMTime(seconds: seekTo, preferredTimescale: 600), toleranceBefore: CMTime(seconds: 1, preferredTimescale: 600), toleranceAfter: .zero) { [weak self] _ in
                    Task { @MainActor [weak self] in self?.player.play() }
                }
            } else {
                player.play()
            }
            Log.info(.playback, "Native engine ready (\(item.tracks.count) tracks, duration \(duration.clockString))")
        case .failed:
            let error = item.error as NSError?
            Log.error(.playback, "Native engine item failed: \(AVPlayerDiagnostics.describe(item))")
            let detail = "\(error?.domain ?? "") \(error?.code ?? 0): \(error?.localizedDescription ?? "unknown") \(item.errorLog()?.events.last?.errorComment ?? "")"
            fail(VelaError(classify(error), detail: detail))
        default:
            break
        }
    }

    private func classify(_ error: NSError?) -> VelaErrorKind {
        guard let error else { return .videoLoadFailed }
        if error.domain == NSURLErrorDomain {
            let code = URLError.Code(rawValue: error.code)
            // The server answered but not with playable media: that is a playback problem, not connectivity.
            if [.badServerResponse, .zeroByteResource, .cannotDecodeRawData, .cannotDecodeContentData, .cannotParseResponse].contains(code) {
                return .videoLoadFailed
            }
            return URLError(code).velaKind
        }
        if error.domain == AVFoundationErrorDomain {
            switch error.code {
            case AVError.Code.fileFormatNotRecognized.rawValue, AVError.Code.decoderNotFound.rawValue, AVError.Code.failedToParse.rawValue, AVError.Code.contentIsNotAuthorized.rawValue:
                return .formatUnsupported
            case AVError.Code.mediaServicesWereReset.rawValue:
                return .videoLoadFailed
            default:
                return .videoLoadFailed
            }
        }
        return .videoLoadFailed
    }

    private func timeControlChanged(_ status: AVPlayer.TimeControlStatus) {
        guard didStartPlaying else { return }
        switch status {
        case .playing:
            setState(.playing)
        case .paused:
            if state != .ended, state != .loading { setState(.paused) }
        case .waitingToPlayAtSpecifiedRate:
            setState(.buffering)
        @unknown default:
            break
        }
    }

    private func setState(_ new: PlaybackEngineState) {
        guard new != state else { return }
        state = new
        delegate?.engine(self, didChangeState: new)
    }

    private func fail(_ error: VelaError) {
        if case .failed = state { return }
        setState(.failed(error))
        delegate?.engine(self, didFail: error)
    }

    // MARK: Transport

    func play() { player.play() }
    func pause() { player.pause() }

    func seek(to time: TimeInterval) {
        let target = CMTime(seconds: max(0, time), preferredTimescale: 600)
        let ranges = (player.currentItem?.seekableTimeRanges ?? []).compactMap { $0.timeRangeValue }
            .map { "\(Int($0.start.seconds))-\(Int($0.end.seconds))" }.joined(separator: ",")
        let before = player.currentTime().seconds
        Log.info(.playback, "Native engine seek to \(time.clockString) from \(before.clockString); seekable [\(ranges)] duration \(duration.clockString)")
        player.seek(to: target, toleranceBefore: CMTime(seconds: 0.5, preferredTimescale: 600), toleranceAfter: CMTime(seconds: 0.5, preferredTimescale: 600)) { [weak self] finished in
            Task { @MainActor [weak self] in
                guard let self else { return }
                Log.info(.playback, "Native engine seek \(finished ? "landed" : "cancelled") at \(self.player.currentTime().seconds.clockString)")
                guard finished else { return }
                self.delegate?.engineDidCompleteSeek(self)
            }
        }
    }

    func stop() {
        teardownItemObservers()
        bitmapSubtitle?.stop()
        bitmapSubtitle = nil
        player.pause()
        player.replaceCurrentItem(with: nil)
        controller.contextualActions = []
        audibleGroup = nil
        legibleGroup = nil
        appliedAudioOption = nil
        appliedLegibleOption = nil
        systemRenderedSubtitle = nil
        state = .idle
    }

    // MARK: Tracks

    /// Embedded selections: map Jellyfin stream order onto AVFoundation's option order.
    private func applyInitialMediaSelection() {
        guard let request else { return }
        if let audio = request.audioStreamIndex { _ = selectAudio(streamIndex: audio) }
        _ = selectSubtitle(streamIndex: request.subtitleStreamIndex)
    }

    func selectAudio(streamIndex: Int) -> Bool {
        guard let request, let item = player.currentItem else { return false }
        guard let group = audibleGroup else {
            // Selection groups are not loaded yet; the initial track is applied once they are.
            return request.audioStreamIndex == streamIndex
        }
        if request.isHLS {
            // Jellyfin transcodes/remuxes a single audio track into HLS; other tracks need a new stream.
            return request.audioStreamIndex == streamIndex
        }
        let audioStreams = request.mediaSource.audioStreams
        guard let ordinal = audioStreams.firstIndex(where: { $0.index == streamIndex }), ordinal < group.options.count else {
            return group.options.count <= 1 && request.audioStreamIndex == streamIndex
        }
        appliedAudioOption = group.options[ordinal]
        item.select(group.options[ordinal], in: group)
        selectedAudio = streamIndex
        return true
    }

    func selectSubtitle(streamIndex: Int?) -> Bool {
        guard let request, let item = player.currentItem else { return false }
        let legible = legibleGroup
        func selectLegible(_ option: AVMediaSelectionOption?) {
            guard let legible else { return }
            appliedLegibleOption = option
            item.select(option, in: legible)
        }
        guard let streamIndex else {
            selectLegible(nil)
            selectedSubtitle = nil
            systemRenderedSubtitle = nil
            return true
        }
        guard let stream = request.mediaSource.stream(index: streamIndex) else { return false }
        if stream.isBitmapSubtitle { return false }
        if request.externalSubtitles.contains(where: { $0.streamIndex == streamIndex }) {
            // Rendered by Vela's overlay; make sure no embedded track shows at the same time.
            selectLegible(nil)
            selectedSubtitle = streamIndex
            systemRenderedSubtitle = nil
            return true
        }
        // Embedded text track (tx3g): pick by ordinal among embedded text subtitles.
        if let legible {
            let embedded = request.mediaSource.subtitleStreams.filter { $0.isExternal != true && $0.isTextSubtitle }
            if let ordinal = embedded.firstIndex(where: { $0.index == streamIndex }), ordinal < legible.options.count {
                selectLegible(legible.options[ordinal])
                selectedSubtitle = streamIndex
                systemRenderedSubtitle = streamIndex
                return true
            }
        }
        return false
    }

    /// The user picked a track in the system's transport-bar menu: map AVFoundation's option back to the
    /// Jellyfin stream so the coordinator can report and remember it.
    private func systemMediaSelectionChanged() {
        guard let request, let item = player.currentItem else { return }
        if let group = audibleGroup {
            let option = item.currentMediaSelection.selectedMediaOption(in: group)
            if option != appliedAudioOption, let option, let ordinal = group.options.firstIndex(of: option) {
                appliedAudioOption = option
                let audioStreams = request.mediaSource.audioStreams
                if ordinal < audioStreams.count {
                    let index = audioStreams[ordinal].index
                    if index != selectedAudio {
                        selectedAudio = index
                        delegate?.engine(self, requestsAudioTrack: index)
                    }
                }
            }
        }
        if let group = legibleGroup {
            let option = item.currentMediaSelection.selectedMediaOption(in: group)
            guard option != appliedLegibleOption else { return } // our own change echoed back
            appliedLegibleOption = option
            let embedded = request.mediaSource.subtitleStreams.filter { $0.isExternal != true && $0.isTextSubtitle }
            if let option, let ordinal = group.options.firstIndex(of: option) {
                if ordinal < embedded.count, embedded[ordinal].index != selectedSubtitle {
                    selectedSubtitle = embedded[ordinal].index
                    systemRenderedSubtitle = selectedSubtitle
                    delegate?.engine(self, requestsSubtitleTrack: selectedSubtitle)
                }
            } else if let current = systemRenderedSubtitle, current == selectedSubtitle {
                // Switched off in the system menu; overlay-rendered tracks are never affected by it.
                selectedSubtitle = nil
                systemRenderedSubtitle = nil
                delegate?.engine(self, requestsSubtitleTrack: nil)
            }
        }
    }

    // MARK: Menus, skip and next episode

    func updateSkipAction(title: String?) {
        skipTitle = title
        updateContextualActions()
    }

    private func updateContextualActions() {
        guard let skipTitle else {
            controller.contextualActions = []
            return
        }
        let action = UIAction(title: skipTitle, image: UIImage(systemName: "forward.end")) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.delegate?.engineRequestsSkip(self)
            }
        }
        controller.contextualActions = [action]
    }

    func updateNextEpisode(_ item: BaseItem?, artworkURL: URL?, creditsStart: TimeInterval?, autoplay: Bool) {
        guard let playerItem = player.currentItem else { return }
        guard let item, let creditsStart, creditsStart > 0 else {
            playerItem.nextContentProposal = nil
            lastProposalItemId = nil
            return
        }
        guard lastProposalItemId != item.id + "\(Int(creditsStart))" else { return }
        lastProposalItemId = item.id + "\(Int(creditsStart))"
        let title = [item.seriesName, item.episodeLabel, item.name].compactMap { $0 }.joined(separator: " · ")
        let proposal = AVContentProposal(contentTimeForTransition: CMTime(seconds: creditsStart, preferredTimescale: 600), title: title, previewImage: nil)
        proposal.automaticAcceptanceInterval = autoplay ? -1 : 0
        proposal.metadata = [metadataItem(.commonIdentifierTitle, title)]
        playerItem.nextContentProposal = proposal
        if let artworkURL {
            Task { [weak self] in
                guard let self else { return }
                if let image = try? await ImagePipelineHolder.shared.image(for: artworkURL, targetSize: CGSize(width: 600, height: 338)) {
                    guard self.player.currentItem === playerItem else { return }
                    let refreshed = AVContentProposal(contentTimeForTransition: proposal.contentTimeForTransition, title: title, previewImage: image)
                    refreshed.automaticAcceptanceInterval = proposal.automaticAcceptanceInterval
                    playerItem.nextContentProposal = refreshed
                }
            }
        }
    }

    func updateTrackMenus(audio: [PlayerTrack], subtitles: [PlayerTrack], selectedAudio: Int?, selectedSubtitle: Int?) {
        audioMenuTracks = audio
        subtitleMenuTracks = subtitles
        self.selectedAudio = selectedAudio
        self.selectedSubtitle = selectedSubtitle
        rebuildTransportMenus()
    }

    private func rebuildTransportMenus() {
        var menus: [UIMenuElement] = []
        // Progressive files with several audio tracks get the system's own audio menu (selection is synced back
        // via `mediaSelectionDidChangeNotification`); HLS carries one track, so Jellyfin's list is offered instead.
        let systemShowsAudioMenu = (request?.isHLS == false) && (audibleGroup?.options.count ?? 0) > 1
        if audioMenuTracks.count > 1, !systemShowsAudioMenu {
            let actions = audioMenuTracks.map { track in
                UIAction(title: track.title, subtitle: track.detail, state: track.streamIndex == selectedAudio ? .on : .off) { [weak self] _ in
                    Task { @MainActor [weak self] in
                        guard let self, let index = track.streamIndex else { return }
                        self.delegate?.engine(self, requestsAudioTrack: index)
                    }
                }
            }
            menus.append(UIMenu(title: L10n.audio, image: UIImage(systemName: "waveform"), children: actions))
        }
        // Progressive MP4 with tx3g tracks: the system shows those itself; a second menu would duplicate it.
        let embeddedTextOnly = subtitleMenuTracks.allSatisfy { $0.streamIndex == nil || (!$0.isExternal && !$0.isBitmap) }
        let systemShowsSubtitleMenu = (request?.isHLS == false) && (legibleGroup?.options.count ?? 0) > 0 && embeddedTextOnly
        if subtitleMenuTracks.count > 1, !systemShowsSubtitleMenu {
            let actions = subtitleMenuTracks.map { track in
                UIAction(title: track.title, subtitle: track.detail, state: track.streamIndex == selectedSubtitle ? .on : .off) { [weak self] _ in
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        self.delegate?.engine(self, requestsSubtitleTrack: track.streamIndex)
                    }
                }
            }
            menus.append(UIMenu(title: L10n.subtitles, image: UIImage(systemName: "captions.bubble"), children: actions))
        }
        controller.transportBarCustomMenuItems = menus
    }

    // MARK: Metadata & chapters

    private func metadata(for request: EngineLoadRequest) -> [AVMetadataItem] {
        var items = [metadataItem(.commonIdentifierTitle, request.title)]
        if let subtitle = request.subtitle, !subtitle.isEmpty {
            items.append(metadataItem(.iTunesMetadataTrackSubTitle, subtitle))
        }
        return items
    }

    private func metadataItem(_ identifier: AVMetadataIdentifier, _ value: String) -> AVMetadataItem {
        let item = AVMutableMetadataItem()
        item.identifier = identifier
        item.value = value as NSString
        item.extendedLanguageTag = "und"
        return item
    }

    private func chapterGroups(for request: EngineLoadRequest) -> [AVNavigationMarkersGroup] {
        guard request.chapters.count > 1 else { return [] }
        var groups: [AVTimedMetadataGroup] = []
        for (index, chapter) in request.chapters.enumerated() {
            let end = index + 1 < request.chapters.count ? request.chapters[index + 1].start : max(chapter.start + 1, request.mediaSource.runtime ?? chapter.start + 1)
            let range = CMTimeRange(start: CMTime(seconds: chapter.start, preferredTimescale: 600), end: CMTime(seconds: end, preferredTimescale: 600))
            groups.append(AVTimedMetadataGroup(items: [metadataItem(.commonIdentifierTitle, chapter.title)], timeRange: range))
        }
        return [AVNavigationMarkersGroup(title: L10n.chapters, timedNavigationMarkers: groups)]
    }

    // MARK: Statistics

    private func updateStatistics() {
        guard let item = player.currentItem else { return }
        var stats = PlaybackStatistics(engine: "AVFoundation (\(request?.isHLS == true ? "HLS" : "progressive"))")
        if let video = request?.mediaSource.videoStream {
            stats.videoCodec = video.technicalLabel
            stats.resolution = video.width.map { "\($0)×\(video.height ?? 0)" } ?? ""
            stats.frameRate = video.frameRate.map { String(format: "%.3f fps", $0) } ?? ""
            stats.dynamicRange = video.effectiveVideoRange.displayName
        }
        stats.hardwareDecode = "VideoToolbox (system)"
        if let audio = request?.mediaSource.stream(index: selectedAudio ?? request?.audioStreamIndex) {
            stats.audioCodec = audio.technicalLabel
        }
        if let range = item.loadedTimeRanges.first?.timeRangeValue {
            let end = range.end.seconds
            stats.bufferedSeconds = max(0, end - currentTime)
        }
        if let access = item.accessLog()?.events.last {
            if access.indicatedBitrate > 0 { stats.bitrate = String(format: "%.1f Mbit/s (indicated)", access.indicatedBitrate / 1_000_000) }
            else if access.observedBitrate > 0 { stats.bitrate = String(format: "%.1f Mbit/s (observed)", access.observedBitrate / 1_000_000) }
            stats.droppedFrames = max(0, access.numberOfDroppedVideoFrames)
            if access.numberOfStalls > 0 { stats.extra = "Stalls: \(access.numberOfStalls)" }
        }
        statistics = stats
    }

    // MARK: Subtitle overlay

    private func installSubtitleOverlay() {
        // contentOverlayView only exists once the controller's view is loaded.
        controller.loadViewIfNeeded()
        let host = UIHostingController(rootView: NativeSubtitleOverlay(engine: self))
        host.view.backgroundColor = .clear
        host.view.isUserInteractionEnabled = false
        host.view.translatesAutoresizingMaskIntoConstraints = false
        controller.addChild(host)
        if let overlay = controller.contentOverlayView {
            overlay.addSubview(host.view)
            NSLayoutConstraint.activate([
                host.view.leadingAnchor.constraint(equalTo: overlay.leadingAnchor),
                host.view.trailingAnchor.constraint(equalTo: overlay.trailingAnchor),
                host.view.topAnchor.constraint(equalTo: overlay.topAnchor),
                host.view.bottomAnchor.constraint(equalTo: overlay.bottomAnchor),
            ])
        }
        host.didMove(toParent: controller)
        subtitleOverlay = host
    }

    /// The transport bar covers the lower part of the screen; lift subtitles while it is visible.
    private(set) var transportBarVisible = false

    func setControlsVisible(_ visible: Bool) {} // the system transport bar is handled via its delegate callback

    func setBitmapSubtitle(_ source: BitmapSubtitleSource?) {
        if bitmapSubtitle !== source { bitmapSubtitle?.stop() }
        bitmapSubtitle = source
        subtitleOverlay?.rootView = NativeSubtitleOverlay(engine: self)
    }

    func appDidEnterBackground() { player.pause() }
    func appWillEnterForeground() {}
}

// MARK: - AVPlayerViewControllerDelegate

extension NativePlaybackEngine: AVPlayerViewControllerDelegate {
    nonisolated func playerViewController(_ playerViewController: AVPlayerViewController, willTransitionToVisibilityOfTransportBar visible: Bool, with coordinator: any AVPlayerViewControllerAnimationCoordinator) {
        Task { @MainActor in
            self.transportBarVisible = visible
            self.subtitleOverlay?.rootView = NativeSubtitleOverlay(engine: self)
        }
    }

    nonisolated func playerViewController(_ playerViewController: AVPlayerViewController, shouldPresent proposal: AVContentProposal) -> Bool {
        true
    }

    nonisolated func playerViewController(_ playerViewController: AVPlayerViewController, didAccept proposal: AVContentProposal) {
        Task { @MainActor in
            self.delegate?.engineRequestsNextItem(self)
        }
    }

    nonisolated func playerViewController(_ playerViewController: AVPlayerViewController, didReject proposal: AVContentProposal) {
        // The user wants to watch the credits; nothing to do.
    }

    nonisolated func skipToNextItem(for playerViewController: AVPlayerViewController) {
        Task { @MainActor in self.delegate?.engineRequestsNextItem(self) }
    }

    nonisolated func skipToPreviousItem(for playerViewController: AVPlayerViewController) {
        Task { @MainActor in self.delegate?.engineRequestsPreviousItem(self) }
    }
}

/// Lets UIKit-side code reach the app's image pipeline without a SwiftUI environment.
@MainActor
enum ImagePipelineHolder {
    static var shared = ImagePipeline()
}
