#if DEBUG
import SwiftUI
import AVKit
import FoyerFoundation

/// `-play-url <url>` (debug builds): plays a URL in a plain AVPlayerViewController with default settings
/// and logs everything AVFoundation reports. Compares the stock system player with the native engine
/// when a stream fails on a real device.
struct DebugURLPlayerScreen: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        let item = AVPlayerItem(url: url)
        let player = AVPlayer(playerItem: item)
        controller.player = player
        context.coordinator.observe(item: item, player: player)
        Log.notice(.playback, "DebugURLPlayer: loading \(url.absoluteString)")
        player.play()
        // `-play-seek <seconds>` seeks after `-play-seek-after` seconds (default 12) the way the native engine does.
        if let target = UserDefaults.standard.string(forKey: "play-seek").flatMap(Double.init) {
            let delay = UserDefaults.standard.string(forKey: "play-seek-after").flatMap(Double.init) ?? 12
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(delay))
                let ranges = (item.seekableTimeRanges).compactMap { $0.timeRangeValue }.map { "\(Int($0.start.seconds))-\(Int($0.end.seconds))" }.joined(separator: ",")
                Log.notice(.playback, "DebugURLPlayer: seeking to \(Int(target)) s from \(player.currentTime().seconds) s; seekable [\(ranges)]; duration \(item.duration.seconds)")
                player.seek(to: CMTime(seconds: target, preferredTimescale: 600), toleranceBefore: CMTime(seconds: 0.5, preferredTimescale: 600),
                            toleranceAfter: CMTime(seconds: 0.5, preferredTimescale: 600)) { finished in
                    Task { @MainActor in
                        Log.notice(.playback, "DebugURLPlayer: seek \(finished ? "landed" : "cancelled") at \(player.currentTime().seconds) s; \(AVPlayerDiagnostics.describe(item))")
                    }
                }
            }
        }
        return controller
    }

    func updateUIViewController(_ controller: AVPlayerViewController, context: Context) {}

    func makeCoordinator() -> Observer { Observer() }

    final class Observer {
        private var observations: [NSKeyValueObservation] = []
        private var tokens: [NSObjectProtocol] = []

        func observe(item: AVPlayerItem, player: AVPlayer) {
            observations.append(item.observe(\.status, options: [.new]) { item, _ in
                switch item.status {
                case .readyToPlay: Log.notice(.playback, "DebugURLPlayer: ready; \(AVPlayerDiagnostics.describe(item))")
                case .failed: Log.error(.playback, "DebugURLPlayer: failed; \(AVPlayerDiagnostics.describe(item))")
                default: break
                }
            })
            observations.append(player.observe(\.timeControlStatus, options: [.new]) { player, _ in
                Log.notice(.playback, "DebugURLPlayer: timeControl \(player.timeControlStatus.rawValue) waiting=\(player.reasonForWaitingToPlay?.rawValue ?? "-")")
            })
            let center = NotificationCenter.default
            tokens.append(center.addObserver(forName: .AVPlayerItemFailedToPlayToEndTime, object: item, queue: .main) { note in
                let error = note.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? NSError
                Log.error(.playback, "DebugURLPlayer: failed to play to end: \(AVPlayerDiagnostics.describe(error)); \(AVPlayerDiagnostics.describe(item))")
            })
            tokens.append(center.addObserver(forName: .AVPlayerItemNewErrorLogEntry, object: item, queue: .main) { _ in
                Log.notice(.playback, "DebugURLPlayer: error log: \(AVPlayerDiagnostics.errorLog(item))")
            })
            tokens.append(center.addObserver(forName: .AVPlayerItemNewAccessLogEntry, object: item, queue: .main) { _ in
                if let event = item.accessLog()?.events.last {
                    Log.debug(.playback, "DebugURLPlayer: access \(event.playbackType ?? "-") \(Int(event.indicatedBitrate / 1000)) kbit/s")
                }
            })
        }

        deinit {
            observations.forEach { $0.invalidate() }
            tokens.forEach { NotificationCenter.default.removeObserver($0) }
        }
    }
}
#endif
