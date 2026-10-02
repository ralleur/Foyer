import Foundation
import Observation
import VelaFoundation
import JellyfinKit

/// What the app does when the server relays a remote-control command.
@MainActor
protocol RemoteCommandHandler: AnyObject {
    func remotePlay(_ request: RemotePlayRequest) async
    func remotePlayState(_ command: PlayStateCommand, seekPosition: TimeInterval?)
    func remoteGeneral(_ command: GeneralCommand)
}

/// Text another client asked this device to show (`DisplayMessage`).
struct RemoteMessage: Identifiable, Equatable {
    let id = UUID()
    var header: String?
    var text: String
    var timeout: TimeInterval
}

/// Keeps the session WebSocket (`/socket`) open while signed in so the server can relay
/// "Play on this device", play-state and general commands. Answers the server's keep-alive requests
/// and reconnects with backoff. Without this connection Jellyfin marks the session as not
/// remote-controllable, whatever the posted capabilities say.
@MainActor
@Observable
final class RemoteControlService {
    private(set) var isConnected = false
    /// Message to show on screen; cleared by the banner after its timeout.
    var message: RemoteMessage?
    @ObservationIgnored weak var handler: (any RemoteCommandHandler)?

    @ObservationIgnored private let session: URLSession
    @ObservationIgnored private var client: JellyfinClient?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var socket: URLSessionWebSocketTask?
    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private var keepAlive: Task<Void, Never>?

    init(session: URLSession = URLSession(configuration: .default)) {
        self.session = session
    }

    /// Connects for this client (idempotent while the same client stays active).
    func connect(client: JellyfinClient) {
        if self.client === client, loop != nil { return }
        disconnect()
        self.client = client
        startLoop()
    }

    func disconnect() {
        stopLoop()
        client = nil
    }

    /// tvOS drops sockets while the app is suspended; called on background/foreground transitions.
    func suspend() { stopLoop() }
    func resume() { if client != nil, loop == nil { startLoop() } }

    private func startLoop() {
        generation += 1
        let current = generation
        loop = Task { [weak self] in await self?.run(generation: current) }
    }

    private func stopLoop() {
        generation += 1
        loop?.cancel()
        loop = nil
        keepAlive?.cancel()
        keepAlive = nil
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
        isConnected = false
    }

    private func run(generation: Int) async {
        var delay = 2
        while !Task.isCancelled, generation == self.generation, let client {
            guard let request = client.webSocketRequest(), let url = request.url else { return }
            let task = session.webSocketTask(with: request)
            task.maximumMessageSize = 4 * 1024 * 1024
            socket = task
            task.resume()
            Log.info(.jellyfin, "Session socket connecting to \(url.host ?? "server")")
            do {
                while !Task.isCancelled, generation == self.generation {
                    let frame = try await task.receive()
                    if !isConnected {
                        isConnected = true
                        delay = 2
                        Log.info(.jellyfin, "Session socket connected")
                    }
                    handle(frame)
                }
            } catch {
                guard !Task.isCancelled, generation == self.generation else { break }
                Log.notice(.jellyfin, "Session socket closed: \(error.localizedDescription); retry in \(delay) s")
            }
            isConnected = false
            keepAlive?.cancel()
            keepAlive = nil
            socket = nil
            try? await Task.sleep(for: .seconds(delay))
            delay = min(delay * 2, 30)
        }
        if generation == self.generation { loop = nil }
    }

    private func handle(_ frame: URLSessionWebSocketTask.Message) {
        let data: Data
        switch frame {
        case .data(let payload): data = payload
        case .string(let text): data = Data(text.utf8)
        @unknown default: return
        }
        guard let message = SessionMessage.parse(data) else {
            Log.debug(.jellyfin, "Session socket: unreadable frame (\(data.count) bytes)")
            return
        }
        dispatch(message)
    }

    /// Routes one parsed frame. Internal so tests can feed frames without a socket.
    func dispatch(_ message: SessionMessage) {
        switch message {
        case .forceKeepAlive(let seconds):
            startKeepAlive(every: max(5, seconds / 2))
        case .keepAlive:
            break
        case .other(let type):
            Log.debug(.jellyfin, "Session socket: \(type)")
        case .command(let command):
            Log.info(.jellyfin, "Remote command: \(command)")
            guard let handler else { return }
            switch command {
            case .play(let request):
                Task { await handler.remotePlay(request) }
            case .playState(let state, let ticks):
                handler.remotePlayState(state, seekPosition: ticks.map { Double($0) / 10_000_000 })
            case .general(let general):
                handler.remoteGeneral(general)
            }
        }
    }

    private func startKeepAlive(every seconds: Int) {
        keepAlive?.cancel()
        keepAlive = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(seconds))
                guard !Task.isCancelled, let socket = self?.socket else { return }
                try? await socket.send(.string(SessionMessage.keepAliveFrame))
            }
        }
    }
}
