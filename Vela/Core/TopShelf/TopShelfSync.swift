import Foundation
import TVServices
import VelaFoundation
import JellyfinKit
import TopShelfKit

/// Keeps the Top Shelf extension's view of Vela current: which account to load, the last Home
/// data as an offline fallback, and a nudge to tvOS whenever that changed.
@MainActor
enum TopShelfSync {
    /// Off under UI tests so canned fixtures never reach the real home screen.
    static var isEnabled = true

    static func activeAccountChanged(_ account: ServerAccount?) {
        guard isEnabled, let store = AppGroup.topShelfStore else { return }
        let shared = account.map {
            TopShelfStore.Account(accountId: $0.id, serverURL: $0.serverURL, userId: $0.userId, tokenKey: $0.tokenKey,
                                  deviceId: DeviceInfo.persistentDeviceId, deviceName: DeviceInfo.deviceName,
                                  clientVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0")
        }
        guard store.loadAccount() != shared else { return }
        store.saveAccount(shared)
        TVTopShelfContentProvider.topShelfContentDidChange()
        Log.info(.ui, shared == nil ? "Top Shelf cleared" : "Top Shelf now follows \(account?.userName ?? "?")@\(account?.serverName ?? "?")")
    }

    /// Called after Home loaded fresh data.
    static func publish(accountId: String, resume: [BaseItem], nextUp: [BaseItem], latest: [[BaseItem]], client: JellyfinClient) {
        guard isEnabled, let store = AppGroup.topShelfStore, store.loadAccount()?.accountId == accountId else { return }
        let snapshot = TopShelfBuilder.snapshot(accountId: accountId, resume: resume, nextUp: nextUp, latest: latest, images: ItemImages(client: client))
        var previous = store.loadSnapshot()
        previous?.created = snapshot.created
        store.saveSnapshot(snapshot)
        if previous != snapshot { TVTopShelfContentProvider.topShelfContentDidChange() }
    }
}
