import Foundation
import TVServices
import VelaFoundation
import JellyfinKit
import TopShelfKit

/// Fills the row above Vela's tile on the Apple TV home screen with "Continue Watching" and
/// "Recently Added". Loads live from Jellyfin with the app's shared token and falls back to the
/// snapshot the app wrote last (server offline, token not shared yet).
final class ContentProvider: TVTopShelfContentProvider {
    /// `Library/Caches/Logs/topshelf.log` in the App Group container (fetch with `Scripts/device-logs.sh`).
    private static let logFile: FileLogSink? = AppGroup.containerURL.map {
        FileLogSink(url: $0.appendingPathComponent("Library/Caches/Logs/topshelf.log"), maxBytes: 300_000)
    }

    override init() {
        super.init()
        Log.shared.configure(sinks: [OSLogSink(subsystem: "com.ralleur.vela.topshelf")] + (Self.logFile.map { [$0] } ?? []), minimumLevel: .info)
    }

    override func loadTopShelfContent(completionHandler: @escaping ((any TVTopShelfContent)?) -> Void) {
        let completion = UncheckedSendable(completionHandler)
        Task {
            let snapshot = await Self.currentSnapshot()
            Log.info(.ui, "Top Shelf delivers \(snapshot.map { $0.sections.map { "\($0.kind.rawValue): \($0.entries.count)" }.joined(separator: ", ") } ?? "nothing (static image)")")
            Self.logFile?.flush()
            completion.value(snapshot.map(Self.content(for:)))
        }
    }

    private static func currentSnapshot() async -> TopShelfSnapshot? {
        guard let store = AppGroup.topShelfStore else {
            Log.warning(.ui, "Top Shelf: App Group \(AppGroup.identifier) unavailable")
            return nil
        }
        guard let account = store.loadAccount() else {
            Log.notice(.ui, "Top Shelf: no signed-in account shared by the app")
            return nil
        }
        if let token = KeychainStore().get(account.tokenKey) {
            let client = JellyfinClient(baseURL: account.serverURL, identity: account.identity, transport: URLSessionTransport(timeout: 10),
                                        accessToken: token, userId: account.userId)
            do {
                let fresh = try await TopShelfLoader.load(client: client, accountId: account.accountId)
                store.saveSnapshot(fresh)
                return fresh.isEmpty ? nil : fresh
            } catch {
                Log.notice(.jellyfin, "Top Shelf live load failed, using the stored snapshot: \(VelaError.wrap(error))")
            }
        } else {
            Log.notice(.jellyfin, "Top Shelf: token not in the shared Keychain, using the stored snapshot")
        }
        return store.loadSnapshot().flatMap { $0.isEmpty ? nil : $0 }
    }

    private static func content(for snapshot: TopShelfSnapshot) -> any TVTopShelfContent {
        let collections = snapshot.sections.map { section in
            let items = section.entries.map { entry in
                let item = TVTopShelfSectionedItem(identifier: entry.id)
                item.title = entry.title
                item.imageShape = section.shape == .poster ? .poster : .hdtv
                item.setImageURL(entry.imageURL1x, for: .screenScale1x)
                item.setImageURL(entry.imageURL2x, for: .screenScale2x)
                if let progress = entry.progress { item.playbackProgress = progress }
                item.displayAction = TVTopShelfAction(url: entry.displayURL)
                item.playAction = entry.playURL.map(TVTopShelfAction.init(url:))
                return item
            }
            let collection = TVTopShelfItemCollection(items: items)
            collection.title = title(for: section.kind)
            return collection
        }
        return TVTopShelfSectionedContent(sections: collections)
    }

    private static func title(for kind: TopShelfSnapshot.Section.Kind) -> String {
        switch kind {
        case .continueWatching: String(localized: "Continue Watching", table: "TopShelf")
        case .recentlyAdded: String(localized: "Recently Added", table: "TopShelf")
        }
    }
}
