import Foundation
import VelaFoundation
import JellyfinKit
import TopShelfKit

extension AppEnvironment {
    /// Handles `vela://` links (Top Shelf): `play` starts or resumes the item, `item` opens its
    /// detail screen on the Home tab.
    func open(_ url: URL) {
        guard let link = VelaLink(url: url) else {
            Log.notice(.ui, "Ignoring unknown link \(url.absoluteString)")
            return
        }
        guard let client else {
            Log.notice(.ui, "Link \(url.absoluteString) arrived without a signed-in account")
            return
        }
        Log.info(.ui, "Opening link \(url.absoluteString)")
        Task {
            do {
                let item = try await client.item(id: link.itemId)
                switch link {
                case .play:
                    play(item, start: .automatic)
                case .item:
                    playback?.close()
                    pendingDetail = item
                }
            } catch {
                Log.warning(.ui, "Link \(url.absoluteString) failed: \(VelaError.wrap(error))")
            }
        }
    }
}
