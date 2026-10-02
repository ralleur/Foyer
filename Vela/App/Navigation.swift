import SwiftUI
import JellyfinKit

/// Resolves an item to its detail screen. Used by every NavigationStack in the app.
struct ItemDestination: View {
    let item: BaseItem

    var body: some View {
        switch item.type {
        case .series?:
            SeriesDetailView(seriesId: item.id, initialSeries: item)
        case .season?:
            SeriesDetailView(seriesId: item.seriesId ?? item.id, initialSeries: nil, initialSeasonId: item.id)
        case .boxSet?, .collectionFolder?, .folder?, .userView?:
            CollectionDetailView(container: item)
        default:
            ItemDetailView(itemId: item.id, initialItem: item)
        }
    }
}

/// Wrapper so nested pushes from detail screens don't collide with the tab's `BaseItem` destination.
struct NavigationTarget: Hashable {
    let item: BaseItem
}

extension View {
    /// Registers the shared item navigation destinations (call once per NavigationStack).
    func itemDestinations() -> some View {
        navigationDestination(for: BaseItem.self) { item in
            ItemDestination(item: item)
        }
        .navigationDestination(for: NavigationTarget.self) { target in
            ItemDestination(item: target.item)
        }
    }
}

/// Where playback should start.
enum PlaybackStart: Hashable {
    /// Resume when the server knows a position, otherwise from the beginning.
    case automatic
    case beginning
    case at(TimeInterval)
}
