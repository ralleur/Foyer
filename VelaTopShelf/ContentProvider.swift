import Foundation
import TVServices
import VelaFoundation
import JellyfinKit
import TopShelfKit

/// Fills the row above Vela's tile on the Apple TV home screen with "Continue Watching" and
/// "Recently Added". Loads live from Jellyfin with the app's shared token and falls back to the
/// snapshot the app wrote last (server offline, token not shared yet).
final class ContentProvider: TVTopShelfContentProvider {
    override func loadTopShelfContent(completionHandler: @escaping ((any TVTopShelfContent)?) -> Void) {
        let completion = UncheckedSendable(completionHandler)
        Task {
            let snapshot = await Self.currentSnapshot()
            completion.value(snapshot.map(Self.content(for:)))
        }
    }

    private static func currentSnapshot() async -> TopShelfSnapshot? {
        guard let store = AppGroup.topShelfStore, let account = store.loadAccount() else { return nil }
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
