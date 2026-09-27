import Foundation
import Observation
import VelaFoundation
import JellyfinKit

/// Remote control from other Jellyfin clients ("Play on …", play-state commands, messages).
extension AppEnvironment: RemoteCommandHandler {
    /// Opens the session socket while an account is active and closes it on sign-out.
    func observeSessionForRemoteControl() {
        remoteControl.handler = self
        sessionDidChangeForRemoteControl()
        trackSessionForRemoteControl()
    }

    private func trackSessionForRemoteControl() {
        withObservationTracking {
            _ = sessionStore.active?.id
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.sessionDidChangeForRemoteControl()
                self.trackSessionForRemoteControl()
            }
        }
    }

    private func sessionDidChangeForRemoteControl() {
        if let client = sessionStore.active?.client, !isUITest {
            remoteControl.connect(client: client)
        } else {
            remoteControl.disconnect()
        }
    }

    // MARK: RemoteCommandHandler

    func remotePlay(_ request: RemotePlayRequest) async {
        guard let client else { return }
        guard request.mode == .playNow else {
            Log.notice(.ui, "Remote play: \(request.mode.rawValue) needs a queue, which Vela does not have")
            return
        }
        guard let id = request.firstItemId else { return }
        do {
            let item = try await client.item(id: id)
            let start: PlaybackStart = request.startPosition.map { $0 > 0 ? .at($0) : .beginning } ?? .automatic
            play(item, mediaSourceId: request.mediaSourceId, start: start,
                 audioStreamIndex: request.audioStreamIndex, subtitleStreamIndex: request.subtitleStreamIndex)
            if request.itemIds.count > 1 {
                Log.notice(.ui, "Remote play: \(request.itemIds.count) items requested, playing the first only (no queue)")
            }
        } catch {
            Log.warning(.jellyfin, "Remote play: item \(id) could not be loaded: \(VelaError.wrap(error))")
        }
    }

    func remotePlayState(_ command: PlayStateCommand, seekPosition: TimeInterval?) {
        guard let playback else {
            Log.debug(.ui, "Remote \(command.rawValue) ignored: nothing is playing")
            return
        }
        switch command {
        case .stop: playback.close()
        case .pause: playback.pause()
        case .unpause: playback.play()
        case .playPause: playback.togglePlayPause()
        case .seek: if let seekPosition { playback.seek(to: seekPosition) }
        case .rewind: playback.seek(by: -10)
        case .fastForward: playback.seek(by: 10)
        case .nextTrack: playback.playNext()
        case .previousTrack: playback.playPrevious()
        }
    }

    func remoteGeneral(_ command: GeneralCommand) {
        switch command.name.lowercased() {
        case "displaymessage":
            let timeout = command.argument("TimeoutMs").flatMap(Double.init).map { $0 / 1000 } ?? 5
            remoteControl.message = RemoteMessage(header: command.argument("Header"), text: command.argument("Text") ?? "", timeout: min(max(2, timeout), 30))
        case "setaudiostreamindex":
            guard let playback, let index = command.argument("Index").flatMap(Int.init),
                  let track = playback.audioTracks.first(where: { $0.streamIndex == index }) else { return }
            playback.selectAudio(track)
        case "setsubtitlestreamindex":
            guard let playback, let index = command.argument("Index").flatMap(Int.init) else { return }
            if index < 0 {
                playback.selectSubtitle(.subtitlesOff)
            } else if let track = playback.subtitleTracks.first(where: { $0.streamIndex == index }) {
                playback.selectSubtitle(track)
            }
        default:
            Log.notice(.ui, "Remote command \(command.name) is not supported")
        }
    }
}
