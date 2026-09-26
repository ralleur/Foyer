import Foundation
import Observation
import FoyerFoundation
import JellyfinKit

/// The signed-in state: account metadata plus a configured client.
struct ActiveSession: Identifiable {
    let account: ServerAccount
    let client: JellyfinClient
    var user: User?

    var id: String { account.id }
}

/// Owns saved accounts, the active session and the sign-in flows.
@MainActor
@Observable
final class SessionStore {
    private(set) var accounts: [ServerAccount] = []
    private(set) var active: ActiveSession?
    /// Set when the server rejected the token; the UI offers to sign in again.
    var expiredAccount: ServerAccount?

    private let defaults: UserDefaults
    private let keychain: any SecretStore
    private let transportFactory: @Sendable () -> any HTTPTransport
    private let accountsKey = "foyer.accounts"
    private let activeKey = "foyer.activeAccount"

    init(transportFactory: @escaping @Sendable () -> any HTTPTransport, keychain: any SecretStore, defaults: UserDefaults = .standard) {
        self.transportFactory = transportFactory
        self.keychain = keychain
        self.defaults = defaults
        restore()
    }

    // MARK: Persistence

    private func restore() {
        if let data = defaults.data(forKey: accountsKey), let saved = try? JSONDecoder().decode([ServerAccount].self, from: data) {
            accounts = saved.sorted { $0.lastUsed > $1.lastUsed }
        }
        if let activeId = defaults.string(forKey: activeKey), let account = accounts.first(where: { $0.id == activeId }) {
            activate(account)
        }
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(accounts) {
            defaults.set(data, forKey: accountsKey)
        }
        defaults.set(active?.account.id, forKey: activeKey)
    }

    // MARK: Client construction

    func makeClient(for url: URL, token: String? = nil, userId: String? = nil) -> JellyfinClient {
        let client = JellyfinClient(baseURL: url, identity: DeviceInfo.identity(), transport: transportFactory(), accessToken: token, userId: userId)
        client.onSessionExpired = { [weak self] in
            Task { @MainActor [weak self] in self?.handleSessionExpired() }
        }
        return client
    }

    // MARK: Discovery

    /// Tries the candidate URLs derived from user input and returns the first reachable Jellyfin server.
    func discover(_ input: String) async throws -> DiscoveredServer {
        let candidates = ServerAddress.candidates(for: input)
        guard !candidates.isEmpty else { throw FoyerError(.invalidServerAddress, detail: "No usable URL in '\(input)'") }
        var lastError: FoyerError = FoyerError(.serverUnreachable)
        for url in candidates {
            let client = makeClient(for: url)
            do {
                let info = try await client.publicSystemInfo()
                guard let id = info.id else { throw FoyerError(.serverUnreachable, detail: "Response without server id") }
                Log.info(.jellyfin, "Found server '\(info.serverName ?? "?")' \(info.version ?? "") at \(ServerAddress.display(url))")
                return DiscoveredServer(url: url, name: info.serverName ?? url.host ?? "Jellyfin", id: id, version: info.version)
            } catch {
                lastError = FoyerError.wrap(error)
                Log.notice(.jellyfin, "Probe \(ServerAddress.display(url)) failed: \(lastError)")
                if lastError.kind == .cancelled { throw lastError }
                // A TLS failure on https is worth reporting if http is not an option; otherwise keep trying.
                continue
            }
        }
        throw lastError
    }

    func publicUsers(for server: DiscoveredServer) async -> [User] {
        let client = makeClient(for: server.url)
        return (try? await client.publicUsers()) ?? []
    }

    func quickConnectAvailable(for server: DiscoveredServer) async -> Bool {
        let client = makeClient(for: server.url)
        return (try? await client.quickConnectEnabled()) ?? false
    }

    // MARK: Sign in

    func signIn(server: DiscoveredServer, username: String, password: String) async throws {
        let client = makeClient(for: server.url)
        let result = try await client.authenticate(username: username, password: password)
        complete(server: server, client: client, result: result)
    }

    /// Runs the Quick Connect flow. `onCode` delivers the code to display; the call returns when authenticated.
    func signInWithQuickConnect(server: DiscoveredServer, onCode: @MainActor (String) -> Void) async throws {
        let client = makeClient(for: server.url)
        let initiated: QuickConnectResult
        do {
            initiated = try await client.quickConnectInitiate()
        } catch let error as FoyerError where error.kind == .notFound || error.kind == .accessDenied {
            throw FoyerError(.quickConnectUnavailable, detail: error.detail)
        }
        guard let secret = initiated.secret, let code = initiated.code else {
            throw FoyerError(.quickConnectUnavailable, detail: "Initiate returned no code")
        }
        onCode(code)
        // Poll until approved on another device (or the code expires server-side).
        let deadline = Date().addingTimeInterval(10 * 60)
        while Date() < deadline {
            try Task.checkCancellation()
            try await Task.sleep(for: .seconds(2))
            let state = try await client.quickConnectState(secret: secret)
            if state.authenticated == true {
                let result = try await client.authenticateWithQuickConnect(secret: secret)
                complete(server: server, client: client, result: result)
                return
            }
        }
        throw FoyerError(.quickConnectUnavailable, detail: "Quick Connect code expired")
    }

    private func complete(server: DiscoveredServer, client: JellyfinClient, result: AuthenticationResult) {
        let account = ServerAccount(serverId: result.serverId ?? server.id, serverName: server.name, serverURL: server.url,
                                    serverVersion: server.version, userId: result.user.id, userName: result.user.name ?? "",
                                    userImageTag: result.user.primaryImageTag, lastUsed: Date())
        keychain.set(result.accessToken, for: account.tokenKey)
        accounts.removeAll { $0.id == account.id }
        accounts.insert(account, at: 0)
        active = ActiveSession(account: account, client: client, user: result.user)
        expiredAccount = nil
        persist()
        Log.info(.jellyfin, "Signed in as \(account.userName) on \(account.serverName)")
        Task { await postCapabilities(client) }
    }

    func activate(_ account: ServerAccount) {
        guard let token = keychain.get(account.tokenKey) else {
            Log.warning(.jellyfin, "No token stored for \(account.userName)@\(account.serverName)")
            expiredAccount = account
            return
        }
        let client = makeClient(for: account.serverURL, token: token, userId: account.userId)
        var updated = account
        updated.lastUsed = Date()
        accounts.removeAll { $0.id == account.id }
        accounts.insert(updated, at: 0)
        active = ActiveSession(account: updated, client: client, user: nil)
        expiredAccount = nil
        persist()
        Task { [weak self] in
            await self?.refreshUser()
            await self?.postCapabilities(client)
        }
    }

    private func refreshUser() async {
        guard let session = active else { return }
        if let user = try? await session.client.currentUser() {
            active?.user = user
            if var account = active?.account {
                account.userName = user.name ?? account.userName
                account.userImageTag = user.primaryImageTag
                active?.account = account
                accounts.removeAll { $0.id == account.id }
                accounts.insert(account, at: 0)
                persist()
            }
        }
    }

    private func postCapabilities(_ client: JellyfinClient) async {
        do {
            try await client.postCapabilities(ClientCapabilities())
        } catch {
            Log.notice(.jellyfin, "Posting capabilities failed: \(error)")
        }
    }

    func signOut(_ account: ServerAccount) async {
        if active?.account.id == account.id, let client = active?.client {
            try? await client.logout()
            active = nil
        }
        keychain.delete(account.tokenKey)
        accounts.removeAll { $0.id == account.id }
        persist()
        Log.info(.jellyfin, "Signed out \(account.userName)@\(account.serverName)")
    }

    func switchAccount(_ account: ServerAccount) {
        guard account.id != active?.account.id else { return }
        activate(account)
    }

    /// Leaves the current session signed in (token kept) but shows onboarding so another server can be added.
    func detachActiveForOnboarding() {
        active = nil
        defaults.removeObject(forKey: activeKey)
    }

    private func handleSessionExpired() {
        guard let account = active?.account else { return }
        Log.warning(.jellyfin, "Session for \(account.userName) expired")
        keychain.delete(account.tokenKey)
        expiredAccount = account
        active = nil
        persist()
    }

    // MARK: UI test support

    func installUITestSession() {
        let url = URL(string: "https://uitest.local")!
        let account = ServerAccount(serverId: "srv1", serverName: "Testserver", serverURL: url, serverVersion: "10.10.3",
                                    userId: "user1", userName: "anna", userImageTag: nil, lastUsed: Date())
        keychain.set("uitest-token", for: account.tokenKey)
        accounts = [account]
        activate(account)
    }
}
