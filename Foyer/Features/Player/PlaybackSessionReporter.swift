import Foundation
import FoyerFoundation
import JellyfinKit
import PlaybackDecision

/// Sends start / progress / stop to the server without flooding it.
@MainActor
final class PlaybackSessionReporter {
    private let client: JellyfinClient
    private let policy = ProgressReportPolicy(interval: 10, minimumSpacing: 1)
    private var lastReport: Date?
    private var timer: Task<Void, Never>?
    private(set) var isActive = false

    struct Context {
        var itemId: String
        var mediaSourceId: String
        var playSessionId: String?
        var playMethod: PlayMethod
        var audioStreamIndex: Int?
        var subtitleStreamIndex: Int?
        var isTranscoding: Bool
    }

    private var context: Context?
    /// Supplies the current position and paused state when a report is due.
    var positionProvider: (@MainActor () -> (position: TimeInterval, isPaused: Bool))?

    init(client: JellyfinClient) {
        self.client = client
    }

    func start(context: Context, position: TimeInterval) {
        self.context = context
        isActive = true
        lastReport = Date()
        let report = makeReport(position: position, isPaused: false, event: nil)
        Task { [client] in
            do {
                try await client.reportPlaybackStart(report)
                Log.info(.jellyfin, "Reported playback start at \(position.clockString) (\(context.playMethod.rawValue))")
            } catch {
                Log.warning(.jellyfin, "Playback start report failed: \(FoyerError.wrap(error))")
            }
        }
        startTimer()
    }

    func updateTracks(audio: Int?, subtitle: Int?) {
        context?.audioStreamIndex = audio
        context?.subtitleStreamIndex = subtitle
        report(trigger: .trackChange)
    }

    func playbackStateChanged(isPaused: Bool) {
        report(trigger: isPaused ? .pause : .resume, event: isPaused ? "pause" : "unpause")
    }

    func didSeek() {
        report(trigger: .seek, event: "timeupdate")
    }

    /// Immediate report regardless of spacing (app going to background, engine switch).
    func flush() {
        guard isActive, let provider = positionProvider else { return }
        let (position, paused) = provider()
        send(makeReport(position: position, isPaused: paused, event: "timeupdate"))
    }

    func stop(position: TimeInterval, failed: Bool = false) async {
        guard isActive, let context else { return }
        isActive = false
        timer?.cancel()
        timer = nil
        let report = PlaybackStopReport(itemId: context.itemId, mediaSourceId: context.mediaSourceId,
                                        playSessionId: context.playSessionId, positionTicks: JellyfinTicks.ticks(seconds: position), failed: failed)
        do {
            try await client.reportPlaybackStopped(report)
            Log.info(.jellyfin, "Reported playback stop at \(position.clockString)")
        } catch {
            Log.warning(.jellyfin, "Playback stop report failed: \(FoyerError.wrap(error))")
        }
        if context.isTranscoding, let session = context.playSessionId {
            try? await client.stopTranscoding(playSessionId: session)
        }
        self.context = nil
    }

    // MARK: Internals

    private func startTimer() {
        timer?.cancel()
        timer = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard let self, self.isActive else { return }
                self.report(trigger: .timer)
            }
        }
    }

    private func report(trigger: ProgressReportPolicy.Trigger, event: String? = nil) {
        guard isActive, let provider = positionProvider else { return }
        let (position, paused) = provider()
        guard policy.shouldReport(trigger: trigger, now: Date(), lastReport: lastReport, isPlaying: !paused) else { return }
        send(makeReport(position: position, isPaused: paused, event: event))
    }

    private func send(_ report: PlaybackStateReport) {
        lastReport = Date()
        Task { [client] in
            do {
                try await client.reportPlaybackProgress(report)
            } catch {
                Log.notice(.jellyfin, "Progress report failed: \(FoyerError.wrap(error))")
            }
        }
    }

    private func makeReport(position: TimeInterval, isPaused: Bool, event: String?) -> PlaybackStateReport {
        let context = context ?? Context(itemId: "", mediaSourceId: "", playSessionId: nil, playMethod: .directPlay,
                                         audioStreamIndex: nil, subtitleStreamIndex: nil, isTranscoding: false)
        return PlaybackStateReport(itemId: context.itemId, mediaSourceId: context.mediaSourceId, playSessionId: context.playSessionId,
                                   positionTicks: JellyfinTicks.ticks(seconds: position), isPaused: isPaused, playMethod: context.playMethod,
                                   audioStreamIndex: context.audioStreamIndex, subtitleStreamIndex: context.subtitleStreamIndex, eventName: event)
    }
}
