import Foundation
import Observation
import FoyerFoundation
import JellyfinKit

/// The user's Jellyfin views, filtered to what a video app can show.
@MainActor
@Observable
final class LibrariesModel {
    private(set) var views: [BaseItem] = []
    private(set) var error: (any Error)?
    private(set) var loaded = false

    var videoLibraries: [BaseItem] {
        views.filter { view in
            guard let type = view.collectionType else { return true }
            return type.isVideoLibrary
        }
    }

    var movieLibraries: [BaseItem] { views.filter { $0.collectionType == .movies } }
    var showLibraries: [BaseItem] { views.filter { $0.collectionType == .tvshows } }
    var collectionLibraries: [BaseItem] { views.filter { $0.collectionType == .boxsets } }

    func load(client: JellyfinClient) async {
        do {
            let fetched = try await client.userViews()
            views = fetched
            error = nil
            loaded = true
            Log.info(.jellyfin, "Loaded \(fetched.count) libraries: \(fetched.map { "\($0.name ?? "?")[\($0.collectionType?.rawValue ?? "mixed")]" })")
        } catch {
            self.error = error
            loaded = true
            Log.error(.jellyfin, "Loading libraries failed: \(FoyerError.wrap(error))")
        }
    }
}
