import Foundation
import Observation
import FoyerFoundation
import JellyfinKit

@MainActor
@Observable
final class OnboardingModel {
    enum Step: Hashable {
        case server
        case users
        case password(User?)
        case quickConnect
    }

    var path: [Step] = []
    var serverInput = ""
    var server: DiscoveredServer?
    var users: [User] = []
    var quickConnectAvailable = false
    var quickConnectCode: String?
    var isBusy = false
    var error: (any Error)?
    private var quickConnectTask: Task<Void, Never>?

    let sessionStore: SessionStore

    init(sessionStore: SessionStore) {
        self.sessionStore = sessionStore
        if let expired = sessionStore.expiredAccount {
            serverInput = ServerAddress.display(expired.serverURL)
        }
    }

    func connect() async {
        guard !isBusy else { return }
        error = nil
        isBusy = true
        defer { isBusy = false }
        do {
            let discovered = try await sessionStore.discover(serverInput)
            server = discovered
            async let users = sessionStore.publicUsers(for: discovered)
            async let quick = sessionStore.quickConnectAvailable(for: discovered)
            self.users = await users
            self.quickConnectAvailable = await quick
            path.append(.users)
        } catch {
            self.error = error
        }
    }

    func choose(_ user: User?) {
        error = nil
        if let user, user.hasPassword == false {
            Task { await signIn(username: user.name ?? "", password: "") }
        } else {
            path.append(.password(user))
        }
    }

    func signIn(username: String, password: String) async {
        guard let server, !isBusy else { return }
        error = nil
        isBusy = true
        defer { isBusy = false }
        do {
            try await sessionStore.signIn(server: server, username: username, password: password)
        } catch {
            self.error = error
            Log.notice(.jellyfin, "Sign in failed: \(FoyerError.wrap(error))")
        }
    }

    func startQuickConnect() {
        guard let server else { return }
        error = nil
        quickConnectCode = nil
        path.append(.quickConnect)
        quickConnectTask?.cancel()
        quickConnectTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await sessionStore.signInWithQuickConnect(server: server) { code in
                    self.quickConnectCode = code
                }
            } catch is CancellationError {
            } catch {
                if !Task.isCancelled { self.error = error }
            }
        }
    }

    func cancelQuickConnect() {
        quickConnectTask?.cancel()
        quickConnectTask = nil
        quickConnectCode = nil
    }

    func useSavedAccount(_ account: ServerAccount) {
        sessionStore.switchAccount(account)
    }
}
