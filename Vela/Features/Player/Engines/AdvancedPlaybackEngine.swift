import Foundation
import UIKit
import QuartzCore
import VelaFoundation
import JellyfinKit
import PlaybackDecision
#if canImport(Libmpv)
import Libmpv
#endif

/// mpv/FFmpeg based engine (MPVKit, LGPL build). Plays MKV/TS/AVI, decodes DTS/TrueHD/FLAC/
/// Opus locally to PCM, renders ASS/PGS/VobSub itself and tone-maps HDR to SDR.
@MainActor
final class AdvancedPlaybackEngine: PlaybackEngine {
    static var isAvailable: Bool {
        #if canImport(Libmpv)
        return true
        #else
        return false
        #endif
    }

    static var versionDescription: String {
        #if canImport(Libmpv)
        return MPVController.versionString
        #else
        return "not linked"
        #endif
    }

    let kind: PlaybackEngineKind = .advanced
    weak var delegate: (any PlaybackEngineDelegate)?
    private(set) var state: PlaybackEngineState = .idle
    private(set) var statistics = PlaybackStatistics(engine: "mpv")
    private(set) var currentTime: TimeInterval = 0
    private(set) var duration: TimeInterval = 0
    var isPlaying: Bool { state == .playing }

    var subtitleDelay: TimeInterval = 0 {
        didSet { controller?.setProperty("sub-delay", double: subtitleDelay) }
    }
    var audioDelay: TimeInterval = 0 {
        didSet { controller?.setProperty("audio-delay", double: audioDelay) }
    }

    private let hostController = MPVHostViewController()
    var viewController: UIViewController { hostController }

    #if canImport(Libmpv)
    private var controller: MPVController?
    #else
    private var controller: NeverController?
    #endif
    private var request: EngineLoadRequest?
    private var fileLoaded = false
    private var isPaused = false
    private var pausedForCache = false
    private var seeking = false
    private var reachedEnd = false
    private var lastTimeReport: TimeInterval = -1
    private var externalSubtitleIds: [Int: Int64] = [:] // Jellyfin index → mpv sid
    private var pendingSubtitle: Int?
    private let images: ImagePipeline
    private var watchdog: Task<Void, Never>?
    private var loadStarted = Date()

    init(images: ImagePipeline) {
        self.images = images
    }

    // MARK: Loading

    func load(_ request: EngineLoadRequest) {
        #if canImport(Libmpv)
        self.request = request
        fileLoaded = false
        reachedEnd = false
        seeking = false
        externalSubtitleIds = [:]
        currentTime = request.startPosition
        duration = request.mediaSource.runtime ?? 0
        setState(.loading)
        loadStarted = Date()

        if controller == nil {
            hostController.loadViewIfNeeded()
            do {
                let created = try MPVController(layer: hostController.metalLayer, options: MPVController.Options())
                created.onEvent = { [weak self] event in self?.handle(event) }
                controller = created
            } catch {
                fail(VelaError.wrap(error))
                return
            }
        }
        guard let controller else { return }
        var options: [String] = []
        if request.startPosition > 1 { options.append("start=\(Int(request.startPosition))") }
        // Audio/subtitle tracks are selected after FILE_LOADED, when mpv's track list (with ff-index) exists.
        options.append("pause=no")
        options.append("sid=no")
        let optionString = options.joined(separator: ",")
        // mpv ≥ 0.38: loadfile <url> <flags> <index> <options>; older builds: loadfile <url> <flags> <options>.
        var result = controller.command(["loadfile", request.url.absoluteString, "replace", "-1", optionString])
        if result == -4 { // MPV_ERROR_INVALID_PARAMETER → legacy three-argument form
            result = controller.command(["loadfile", request.url.absoluteString, "replace", optionString])
        }
        if result < 0 {
            fail(VelaError(.videoLoadFailed, detail: "mpv loadfile failed (\(result))"))
            return
        }
        pendingSubtitle = request.subtitleStreamIndex
        startWatchdog()
        Log.info(.playback, "Advanced engine loading \(request.mediaSource.container ?? "?") from \(request.startPosition.clockString)")
        #else
        fail(VelaError(.formatUnsupported, detail: "Advanced engine not linked"))
        #endif
    }

    /// Fails loading when nothing happens within a reasonable time (unreachable stream).
    private func startWatchdog() {
        watchdog?.cancel()
        watchdog = Task { [weak self] in
            try? await Task.sleep(for: .seconds(30))
            guard let self, !Task.isCancelled, !self.fileLoaded, self.state == .loading else { return }
            self.fail(VelaError(.serverUnreachable, detail: "mpv did not open the stream within 30 s"))
        }
    }

    #if canImport(Libmpv)
    private func handle(_ event: MPVController.Event) {
        switch event {
        case .fileLoaded:
            watchdog?.cancel()
            fileLoaded = true
            applyInitialTracks()
            Log.info(.playback, "Advanced engine opened file in \(Int(Date().timeIntervalSince(loadStarted) * 1000)) ms; video=\(controller?.getString("video-codec") ?? "?") hwdec=\(controller?.getString("hwdec-current") ?? "?")")
            refreshStatistics()
        case .playbackRestart:
            if seeking {
                seeking = false
                delegate?.engineDidCompleteSeek(self)
            }
            updateState()
        case let .endFile(reason, error):
            // MPV_END_FILE_REASON_EOF = 0, STOP = 2, QUIT = 3, ERROR = 4, REDIRECT = 5
            if reason == 4 {
                let message = String(cString: mpv_error_string(error))
                let kind: VelaErrorKind = message.lowercased().contains("unrecognized") || message.lowercased().contains("format") ? .formatUnsupported : .videoLoadFailed
                fail(VelaError(kind, detail: "mpv: \(message)"))
            } else if reason == 0, !reachedEnd {
                handleEndOfFile()
            }
        case let .propertyChanged(name, value):
            propertyChanged(name, value)
        case let .log(prefix, level, text):
            switch level {
            case "fatal", "error": Log.error(.playback, "mpv[\(prefix)] \(text)")
            case "warn": Log.warning(.playback, "mpv[\(prefix)] \(text)")
            default: Log.debug(.playback, "mpv[\(prefix)] \(text)")
            }
        case .shutdown:
            break
        }
    }

    private func propertyChanged(_ name: String, _ value: Any?) {
        switch name {
        case "time-pos":
            guard let time = value as? Double, fileLoaded else { return }
            currentTime = max(0, time)
            if abs(currentTime - lastTimeReport) >= 0.45 || currentTime < lastTimeReport {
                lastTimeReport = currentTime
                refreshStatistics()
                delegate?.engine(self, didUpdateTime: currentTime, duration: duration)
            }
        case "duration":
            if let d = value as? Double, d > 0 { duration = d }
        case "pause":
            isPaused = (value as? Bool) ?? false
            updateState()
        case "paused-for-cache":
            pausedForCache = (value as? Bool) ?? false
            updateState()
        case "seeking":
            if let s = value as? Bool { seeking = s }
            updateState()
        case "eof-reached":
            if let eof = value as? Bool, eof, fileLoaded, !reachedEnd {
                handleEndOfFile()
            }
        case "track-list/count":
            if fileLoaded { applyPendingSubtitleIfNeeded() }
        default:
            break
        }
    }

    /// mpv reports a plain EOF for streams that break off (HTTP errors, unseekable sources). An "end"
    /// long before the known duration is a failure, so the coordinator can try another route instead
    /// of silently closing the player.
    private func handleEndOfFile() {
        let expected = duration > 0 ? duration : (request?.mediaSource.runtime ?? 0)
        if expected > 10, currentTime < expected - 5 {
            fail(VelaError(.videoLoadFailed, detail: "mpv ended at \(currentTime.clockString) of \(expected.clockString) (stream broke off)"))
            return
        }
        reachedEnd = true
        setState(.ended)
        delegate?.engineDidReachEnd(self)
    }

    private func updateState() {
        guard fileLoaded, !reachedEnd else { return }
        if pausedForCache || seeking {
            setState(.buffering)
        } else if isPaused {
            setState(.paused)
        } else {
            setState(.playing)
        }
    }
    #endif

    private func setState(_ new: PlaybackEngineState) {
        guard new != state else { return }
        state = new
        delegate?.engine(self, didChangeState: new)
    }

    private func fail(_ error: VelaError) {
        watchdog?.cancel()
        if case .failed = state { return }
        setState(.failed(error))
        delegate?.engine(self, didFail: error)
    }

    // MARK: Transport

    func play() {
        controller?.setProperty("pause", flag: false)
    }

    func pause() {
        controller?.setProperty("pause", flag: true)
    }

    func seek(to time: TimeInterval) {
        guard let controller, fileLoaded else { return }
        seeking = true
        reachedEnd = false
        currentTime = time
        controller.command(["seek", String(format: "%.3f", time), "absolute+keyframes"])
    }

    func stop() {
        watchdog?.cancel()
        controller?.command(["stop"])
        controller?.destroy()
        controller = nil
        state = .idle
    }

    // MARK: Tracks

    #if canImport(Libmpv)
    /// mpv numbers tracks per type; Jellyfin uses FFmpeg stream indices. `ff-index` bridges the two.
    private func mpvTrackId(forFFmpegIndex index: Int, type: String) -> Int64? {
        guard let controller, let count = controller.getInt("track-list/count") else { return nil }
        for i in 0..<Int(count) {
            guard controller.getString("track-list/\(i)/type") == type else { continue }
            if let ff = controller.getInt("track-list/\(i)/ff-index"), Int(ff) == index {
                return controller.getInt("track-list/\(i)/id")
            }
        }
        // Fallback: ordinal position among tracks of that type.
        guard let request else { return nil }
        let streams = type == "audio" ? request.mediaSource.audioStreams : request.mediaSource.subtitleStreams.filter { $0.isExternal != true }
        guard let ordinal = streams.firstIndex(where: { $0.index == index }) else { return nil }
        var seen = 0
        for i in 0..<Int(count) where controller.getString("track-list/\(i)/type") == type {
            if controller.getFlag("track-list/\(i)/external") == true { continue }
            if seen == ordinal { return controller.getInt("track-list/\(i)/id") }
            seen += 1
        }
        return nil
    }

    private func applyInitialTracks() {
        guard let request else { return }
        if let audio = request.audioStreamIndex { _ = selectAudio(streamIndex: audio) }
        applyPendingSubtitleIfNeeded()
        controller?.setProperty("sub-delay", double: subtitleDelay)
        controller?.setProperty("audio-delay", double: audioDelay)
        if !request.fontURLs.isEmpty {
            Log.debug(.subtitle, "\(request.fontURLs.count) embedded fonts available (libass reads attachments from the container)")
        }
    }

    private func applyPendingSubtitleIfNeeded() {
        guard let pending = pendingSubtitle else { return }
        if selectSubtitle(streamIndex: pending) { pendingSubtitle = nil }
    }
    #endif

    func selectAudio(streamIndex: Int) -> Bool {
        #if canImport(Libmpv)
        guard fileLoaded, let controller else { return true }
        if let id = mpvTrackId(forFFmpegIndex: streamIndex, type: "audio") {
            controller.setProperty("aid", string: String(id))
            return true
        }
        Log.warning(.audio, "No mpv audio track for stream #\(streamIndex)")
        return false
        #else
        return false
        #endif
    }

    func selectSubtitle(streamIndex: Int?) -> Bool {
        #if canImport(Libmpv)
        guard let controller, let request else { return false }
        guard let streamIndex else {
            controller.setProperty("sid", string: "no")
            return true
        }
        guard fileLoaded else {
            pendingSubtitle = streamIndex
            return true
        }
        if let stream = request.mediaSource.stream(index: streamIndex), stream.isExternal == true || externalSubtitleIds[streamIndex] != nil {
            if let sid = externalSubtitleIds[streamIndex] {
                controller.setProperty("sid", string: String(sid))
                return true
            }
            guard let external = request.externalSubtitles.first(where: { $0.streamIndex == streamIndex }) else { return false }
            let before = controller.getInt("track-list/count") ?? 0
            controller.command(["sub-add", external.url.absoluteString, "select", external.title, external.language ?? ""])
            // Find the id of the track that was just added.
            if let count = controller.getInt("track-list/count"), count > before {
                for i in stride(from: Int(count) - 1, through: 0, by: -1) where controller.getString("track-list/\(i)/type") == "sub" {
                    if controller.getFlag("track-list/\(i)/external") == true, let id = controller.getInt("track-list/\(i)/id") {
                        externalSubtitleIds[streamIndex] = id
                        return true
                    }
                }
            }
            return true
        }
        if let id = mpvTrackId(forFFmpegIndex: streamIndex, type: "sub") {
            controller.setProperty("sid", string: String(id))
            return true
        }
        Log.warning(.subtitle, "No mpv subtitle track for stream #\(streamIndex)")
        return false
        #else
        return false
        #endif
    }

    func updateSkipAction(title: String?) {}
    func updateNextEpisode(_ item: BaseItem?, artworkURL: URL?, creditsStart: TimeInterval?, autoplay: Bool) {}
    func updateTrackMenus(audio: [PlayerTrack], subtitles: [PlayerTrack], selectedAudio: Int?, selectedSubtitle: Int?) {}
    func setBitmapSubtitle(_ source: EmbeddedSubtitleSource?) { source?.stop() } // mpv draws PGS/VobSub itself

    /// libass draws at the bottom edge; lift it while the scrubber/panel is showing.
    func setControlsVisible(_ visible: Bool) {
        controller?.setProperty("sub-pos", string: visible ? "80" : "100")
    }

    // MARK: Lifecycle

    func appDidEnterBackground() {
        pause()
        // Detach video output while in background to avoid a black frame on resume.
        controller?.setProperty("vid", string: "no")
    }

    func appWillEnterForeground() {
        controller?.setProperty("vid", string: "auto")
    }

    // MARK: Statistics

    private func refreshStatistics() {
        #if canImport(Libmpv)
        guard let controller, let request else { return }
        var stats = PlaybackStatistics(engine: "mpv (\(AdvancedPlaybackEngine.cachedVersion))")
        stats.videoCodec = controller.getString("video-format").map { $0.uppercased() } ?? request.mediaSource.videoStream?.technicalLabel ?? ""
        if let w = controller.getInt("video-params/w"), let h = controller.getInt("video-params/h") { stats.resolution = "\(w)×\(h)" }
        if let fps = controller.getDouble("container-fps") { stats.frameRate = String(format: "%.3f fps", fps) }
        if let peak = controller.getDouble("video-params/sig-peak"), peak > 1 {
            stats.dynamicRange = "\(request.mediaSource.videoStream?.effectiveVideoRange.displayName ?? "HDR") → SDR tone-mapped"
        } else {
            stats.dynamicRange = "SDR"
        }
        stats.hardwareDecode = controller.getString("hwdec-current").map { $0 == "no" || $0.isEmpty ? "software" : $0 } ?? "?"
        stats.audioCodec = controller.getString("audio-codec-name")?.uppercased() ?? ""
        if let channels = controller.getString("audio-params/hr-channels") ?? controller.getString("audio-params/channels") {
            stats.audioChannels = channels
        }
        stats.droppedFrames = Int(controller.getInt("frame-drop-count") ?? 0)
        stats.bufferedSeconds = controller.getDouble("demuxer-cache-duration") ?? 0
        if let bitrate = controller.getDouble("video-bitrate"), bitrate > 0 {
            stats.bitrate = String(format: "%.1f Mbit/s", bitrate / 1_000_000)
        }
        if let out = controller.getString("audio-out-params/channels") {
            stats.extra = "Output: \(out)"
        }
        statistics = stats
        #endif
    }

    private static let cachedVersion: String = {
        #if canImport(Libmpv)
        return MPVController.versionString
        #else
        return "unavailable"
        #endif
    }()
}

#if !canImport(Libmpv)
/// Placeholder type so the engine compiles when MPVKit is not linked.
final class NeverController {
    func setProperty(_ name: String, string value: String) {}
    func setProperty(_ name: String, flag value: Bool) {}
    func setProperty(_ name: String, double value: Double) {}
    @discardableResult func command(_ args: [String]) -> Int32 { -1 }
    func destroy() {}
}
#endif

/// Hosts the Metal layer mpv draws into.
final class MPVHostViewController: UIViewController {
    let metalLayer = MPVMetalLayer()

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        view.frame = UIScreen.main.bounds
        metalLayer.frame = view.bounds
        metalLayer.contentsScale = UIScreen.main.nativeScale
        metalLayer.framebufferOnly = true
        metalLayer.backgroundColor = UIColor.black.cgColor
        metalLayer.isOpaque = true
        view.layer.addSublayer(metalLayer)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        metalLayer.frame = view.bounds
        CATransaction.commit()
    }
}
