#if DEBUG
import Foundation
import VelaFoundation
import JellyfinKit
import PlaybackDecision

/// `-selftest queue` (debug builds): plays every item listed in `Library/Caches/SelfTest/queue.json` for real
/// (start, progress, each subtitle track, other audio tracks, a seek), restores the item's watch state and
/// appends one JSON line per item to `report.jsonl`. `Tools/Nightly/nightly.py` drives it in the simulator.
@MainActor
final class SelfTestRunner {
    struct Entry: Codable {
        var id: String
        /// Budget for this item; falls back to `perItemSeconds`.
        var seconds: Double?
    }

    struct Queue: Codable {
        var items: [Entry]
        var perItemSeconds: Double?
        /// Local time "HH:MM" after which no new item is started.
        var deadline: String?
        /// Where to start each title (fraction of its runtime, default 0.1) so dialogue and subtitles are likely.
        var startFraction: Double?
        var maxSubtitleTracks: Int?
        var maxAudioTracks: Int?
    }

    struct TrackCheck: Codable {
        var index: Int
        var label: String
        var language: String?
        var result: String   // ok | noEvents | fail | skipped
        var detail: String?
    }

    struct ItemReport: Codable {
        var id: String
        var name: String
        var type: String
        var series: String?
        var episode: String?
        var container: String?
        var video: String?
        var range: String?
        var audio: [String]
        var subtitles: [String]
        var route: String?
        var engine: String?
        var method: String?
        var reasons: [String]
        var compromises: [String]
        var readySeconds: Double?
        var plays: Bool
        var subtitleChecks: [TrackCheck]
        var audioChecks: [TrackCheck]
        var seekResult: String?
        var errors: [String]
        var result: String   // ok | warn | fail
        var durationSeconds: Double
        var timestamp: String
    }

    struct State: Codable {
        var index: Int
        var total: Int
        var finished: Bool
        var startedAt: String
        var updatedAt: String
        var current: String?
        var stoppedReason: String?
    }

    static let directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("SelfTest", isDirectory: true)
    static var queueURL: URL { directory.appendingPathComponent("queue.json") }
    static var reportURL: URL { directory.appendingPathComponent("report.jsonl") }
    static var stateURL: URL { directory.appendingPathComponent("state.json") }

    private unowned let environment: AppEnvironment
    private var task: Task<Void, Never>?
    private let started = Date()

    init(environment: AppEnvironment) {
        self.environment = environment
    }

    func startIfNeeded() {
        guard task == nil else { return }
        task = Task { [weak self] in await self?.run() }
    }

    // MARK: Run

    private func run() async {
        guard let client = environment.client else { return }
        guard let data = try? Data(contentsOf: Self.queueURL), let queue = try? JSONDecoder().decode(Queue.self, from: data) else {
            Log.error(.ui, "Self-test: no queue at \(Self.queueURL.path)")
            return
        }
        try? FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
        let budget = queue.perItemSeconds ?? 150
        let deadline = Self.deadline(from: queue.deadline)
        var state = State(index: 0, total: queue.items.count, finished: false, startedAt: Self.iso(started), updatedAt: Self.iso(Date()), current: nil, stoppedReason: nil)
        Log.notice(.ui, "Self-test: \(queue.items.count) items, \(Int(budget)) s each, deadline \(queue.deadline ?? "none")")
        writeState(state)
        try? await Task.sleep(for: .seconds(2)) // let Home settle
        for (index, entry) in queue.items.enumerated() {
            if let deadline, Date() > deadline {
                state.stoppedReason = "deadline"
                break
            }
            state.index = index
            state.current = entry.id
            state.updatedAt = Self.iso(Date())
            writeState(state)
            let report = await test(itemId: entry.id, client: client, budget: entry.seconds ?? budget, queue: queue, position: index + 1, total: queue.items.count)
            append(report)
            try? await Task.sleep(for: .seconds(2))
        }
        state.index = queue.items.count
        state.finished = true
        state.current = nil
        state.updatedAt = Self.iso(Date())
        writeState(state)
        environment.remoteControl.message = RemoteMessage(header: "Selbsttest", text: "Fertig: \(queue.items.count) Titel", timeout: 30)
        Log.notice(.ui, "Self-test finished (\(state.stoppedReason ?? "all items"))")
    }

    private func test(itemId: String, client: JellyfinClient, budget: Double, queue: Queue, position: Int, total: Int) async -> ItemReport {
        let itemStart = Date()
        let end = itemStart.addingTimeInterval(budget)
        var report = ItemReport(id: itemId, name: itemId, type: "?", audio: [], subtitles: [], reasons: [], compromises: [], plays: false,
                                subtitleChecks: [], audioChecks: [], errors: [], result: "fail", durationSeconds: 0, timestamp: Self.iso(itemStart))
        func finish(_ result: String? = nil) -> ItemReport {
            var out = report
            out.errors = Self.recentProblems(since: itemStart)
            out.durationSeconds = Date().timeIntervalSince(itemStart)
            if let result { out.result = result }
            return out
        }
        // Item and its watch state
        let item: BaseItem
        do { item = try await client.item(id: itemId) } catch {
            report.errors = ["item load failed: \(VelaError.wrap(error))"]
            return finish("fail")
        }
        report.name = item.displayTitle
        report.type = item.type?.rawValue ?? "?"
        report.series = item.seriesName
        report.episode = item.episodeLabel
        if let source = item.mediaSources?.first {
            report.container = source.container
            if let video = source.videoStream {
                report.video = "\(video.technicalLabel) \(video.width ?? 0)×\(video.height ?? 0)"
                report.range = video.effectiveVideoRange.displayName
            }
            report.audio = source.audioStreams.map { "#\($0.index) \($0.technicalLabel) \($0.language ?? "?")" }
            report.subtitles = source.subtitleStreams.map { "#\($0.index) \($0.technicalLabel) \($0.language ?? "?")\($0.isForced == true ? " forced" : "")\($0.isExternal == true ? " ext" : "")" }
        }
        let oldPosition = item.userData?.playbackPositionTicks ?? 0
        let oldPlayed = item.userData?.played ?? false
        environment.remoteControl.message = RemoteMessage(header: "Selbsttest \(position)/\(total)", text: item.displayTitle, timeout: budget)

        // Start
        let runtime = item.runtime ?? 0
        let startAt = max(0, min(runtime * (queue.startFraction ?? 0.1), max(0, runtime - 900)))
        environment.play(item, start: startAt > 5 ? .at(startAt) : .beginning)
        guard let coordinator = environment.playback else {
            report.errors = ["player did not open (item not playable?)"]
            return finish("fail")
        }
        let readyStart = Date()
        let ready = await waitUntil(deadline: min(end, readyStart.addingTimeInterval(75))) {
            coordinator.phase == .ready && coordinator.engineState == .playing || coordinator.isFailed
        }
        report.route = coordinator.decision?.route.rawValue
        report.engine = coordinator.decision?.engine.rawValue
        report.method = coordinator.decision?.method.rawValue
        report.reasons = coordinator.decision?.reasons ?? []
        report.compromises = coordinator.decision?.compromises ?? []
        if ready, !coordinator.isFailed {
            report.readySeconds = (Date().timeIntervalSince(readyStart) * 10).rounded() / 10
            let before = coordinator.currentTime
            _ = await waitUntil(deadline: min(end, Date().addingTimeInterval(15))) { coordinator.currentTime - before >= 8 }
            report.plays = coordinator.currentTime - before >= 5
        }
        if !report.plays {
            report.errors = Self.recentProblems(since: itemStart)
            await closeAndRestore(coordinator, itemId: itemId, client: client, position: oldPosition, played: oldPlayed)
            return finish("fail")
        }

        // Subtitles: preferred languages and forced tracks first, capped
        let preferred = environment.preferences.languages.subtitleLanguages
        let subtitleTracks = coordinator.subtitleTracks.filter { $0.streamIndex != nil }
        let ranked = subtitleTracks.sorted { a, b in
            func score(_ t: PlayerTrack) -> Int {
                var s = 0
                if let language = t.language, preferred.contains(where: { LanguageCode.matches($0, language) }) { s += 10 }
                if t.isForced { s += 3 }
                if t.isBitmap { s += 1 }
                return s
            }
            return score(a) > score(b)
        }
        let subtitleCap = budget < 90 ? 1 : (queue.maxSubtitleTracks ?? 4)
        for track in ranked.prefix(subtitleCap) {
            guard let index = track.streamIndex else { continue }
            guard Date() < end.addingTimeInterval(-40) else {
                report.subtitleChecks.append(TrackCheck(index: index, label: track.title, language: track.language, result: "skipped", detail: "budget"))
                continue
            }
            let check = await checkSubtitle(track, coordinator: coordinator, deadline: min(end, Date().addingTimeInterval(35)))
            report.subtitleChecks.append(check)
        }
        if !subtitleTracks.isEmpty { coordinator.selectSubtitle(.subtitlesOff) }

        // Other audio tracks
        let currentAudio = coordinator.selectedAudioIndex
        let audioCap = budget < 90 ? 0 : (queue.maxAudioTracks ?? 2)
        for track in coordinator.audioTracks.filter({ $0.streamIndex != currentAudio }).prefix(audioCap) {
            guard let index = track.streamIndex, Date() < end.addingTimeInterval(-30) else { continue }
            coordinator.selectAudio(track)
            let ok = await waitUntil(deadline: min(end, Date().addingTimeInterval(40))) {
                coordinator.selectedAudioIndex == index && coordinator.engineState == .playing && !coordinator.isSwitchingEngine || coordinator.isFailed
            }
            let good = ok && !coordinator.isFailed && coordinator.selectedAudioIndex == index
            report.audioChecks.append(TrackCheck(index: index, label: track.title, language: track.language, result: good ? "ok" : "fail",
                                                 detail: good ? nil : (coordinator.isFailed ? "engine failed" : "not playing after switch")))
            if coordinator.isFailed { break }
        }

        // Seek forward
        if !coordinator.isFailed, budget >= 90, Date() < end.addingTimeInterval(-20) {
            let target = min(coordinator.currentTime + (runtime > 1800 ? 600 : 60), max(0, runtime - 120))
            if target > coordinator.currentTime + 30 {
                coordinator.seek(to: target)
                let landed = await waitUntil(deadline: min(end, Date().addingTimeInterval(45))) {
                    abs(coordinator.currentTime - target) < 8 && coordinator.engineState == .playing || coordinator.isFailed
                }
                report.seekResult = landed && !coordinator.isFailed ? "ok" : "fail"
            } else {
                report.seekResult = "skipped"
            }
        }

        await closeAndRestore(coordinator, itemId: itemId, client: client, position: oldPosition, played: oldPlayed)
        let failed = coordinator.isFailed || report.subtitleChecks.contains { $0.result == "fail" } || report.audioChecks.contains { $0.result == "fail" } || report.seekResult == "fail"
        let warned = report.subtitleChecks.contains { $0.result == "noEvents" || $0.result == "skipped" } || !report.compromises.isEmpty
        return finish(failed ? "fail" : (warned ? "warn" : "ok"))
    }

    private func checkSubtitle(_ track: PlayerTrack, coordinator: PlaybackCoordinator, deadline: Date) async -> TrackCheck {
        guard let index = track.streamIndex else { return TrackCheck(index: -1, label: track.title, language: track.language, result: "skipped", detail: nil) }
        let problemsBefore = Self.recentProblems(since: Date()).count
        coordinator.selectSubtitle(track)
        let selected = await waitUntil(deadline: deadline) { coordinator.selectedSubtitleIndex == index && !coordinator.isSwitchingEngine && coordinator.engineState == .playing || coordinator.isFailed }
        if coordinator.isFailed { return TrackCheck(index: index, label: track.title, language: track.language, result: "fail", detail: "engine failed") }
        if !selected { return TrackCheck(index: index, label: track.title, language: track.language, result: "fail", detail: "not selected in time") }
        let engine = coordinator.engineKind
        if engine == .advanced {
            // mpv renders text and bitmaps itself; a selected track that keeps playing is the check we have.
            return TrackCheck(index: index, label: track.title, language: track.language, result: "ok", detail: "rendered by mpv")
        }
        if track.isBitmap {
            let decoded = await waitUntil(deadline: deadline) {
                (coordinator.bitmapSubtitleStatus?.decoded ?? 0) > 0 || coordinator.bitmapSubtitleStatus?.failure != nil
            }
            if let failure = coordinator.bitmapSubtitleStatus?.failure { return TrackCheck(index: index, label: track.title, language: track.language, result: "fail", detail: failure) }
            return TrackCheck(index: index, label: track.title, language: track.language, result: decoded ? "ok" : "noEvents",
                              detail: decoded ? "\(coordinator.bitmapSubtitleStatus?.decoded ?? 0) frames" : "no bitmap within the window")
        }
        let loaded = await waitUntil(deadline: deadline) { coordinator.subtitleTimeline != nil || Self.recentProblems(since: Date().addingTimeInterval(-30)).contains { $0.contains("Subtitle load failed") } }
        if let timeline = coordinator.subtitleTimeline {
            return TrackCheck(index: index, label: track.title, language: track.language, result: timeline.cues.isEmpty ? "noEvents" : "ok", detail: "\(timeline.cues.count) cues")
        }
        _ = problemsBefore
        return TrackCheck(index: index, label: track.title, language: track.language, result: "fail", detail: loaded ? "load failed" : "no cues in time")
    }

    private func closeAndRestore(_ coordinator: PlaybackCoordinator, itemId: String, client: JellyfinClient, position: Int64, played: Bool) async {
        coordinator.close()
        try? await Task.sleep(for: .seconds(2))
        do {
            try await client.updateUserData(itemId: itemId, positionTicks: position, played: played)
        } catch {
            Log.warning(.jellyfin, "Self-test: could not restore watch state for \(itemId): \(VelaError.wrap(error))")
        }
    }

    // MARK: Helpers

    private func waitUntil(deadline: Date, _ condition: @MainActor () -> Bool) async -> Bool {
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(250))
        }
        return condition()
    }

    private static func recentProblems(since date: Date) -> [String] {
        AppLog.buffer.snapshot.filter { $0.date >= date && $0.level >= .warning }.suffix(20).map { "[\($0.category.rawValue)] \($0.message.prefix(300))" }
    }

    private static func deadline(from text: String?) -> Date? {
        guard let text, let hourText = text.split(separator: ":").first, let minuteText = text.split(separator: ":").last,
              let hour = Int(hourText), let minute = Int(minuteText) else { return nil }
        let calendar = Calendar.current
        var components = calendar.dateComponents([.year, .month, .day], from: Date())
        components.hour = hour
        components.minute = minute
        guard var date = calendar.date(from: components) else { return nil }
        if date < Date() { date = calendar.date(byAdding: .day, value: 1, to: date) ?? date }
        return date
    }

    private static func iso(_ date: Date) -> String { ISO8601DateFormatter().string(from: date) }

    private func writeState(_ state: State) {
        if let data = try? JSONEncoder().encode(state) { try? data.write(to: Self.stateURL, options: .atomic) }
    }

    private func append(_ report: ItemReport) {
        guard let data = try? JSONEncoder().encode(report) else { return }
        if let handle = try? FileHandle(forWritingTo: Self.reportURL) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data + Data("\n".utf8))
        } else {
            try? (data + Data("\n".utf8)).write(to: Self.reportURL)
        }
        Log.notice(.ui, "Self-test: \(report.name) → \(report.result) (\(report.route ?? "?"), subs \(report.subtitleChecks.map(\.result).joined(separator: ",")), seek \(report.seekResult ?? "-"))")
    }
}

private extension PlaybackCoordinator {
    var isFailed: Bool {
        if case .failed = phase { return true }
        return false
    }
}
#endif
