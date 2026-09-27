import Foundation

/// Chooses the right Jellyfin artwork (with sensible fallbacks) for a given card type.
public struct ItemImages: Sendable {
    public let client: JellyfinClient

    public init(client: JellyfinClient) {
        self.client = client
    }

    public func poster(_ item: BaseItem, width: Int) -> URL? {
        if item.isEpisode {
            if let seriesId = item.seriesId, let tag = item.seriesPrimaryImageTag {
                return client.imageURL(itemId: seriesId, type: .primary, tag: tag, maxWidth: width)
            }
        }
        if let tag = item.primaryImageTag {
            return client.imageURL(itemId: item.id, type: .primary, tag: tag, maxWidth: width)
        }
        if item.isSeason, let seriesId = item.seriesId, let tag = item.seriesPrimaryImageTag {
            return client.imageURL(itemId: seriesId, type: .primary, tag: tag, maxWidth: width)
        }
        if let parentId = item.parentPrimaryImageItemId, let tag = item.parentPrimaryImageTag {
            return client.imageURL(itemId: parentId, type: .primary, tag: tag, maxWidth: width)
        }
        return nil
    }

    /// 16:9 artwork: episode stills, series/movie thumbs, backdrops.
    public func landscape(_ item: BaseItem, width: Int) -> URL? {
        if item.isEpisode, let tag = item.primaryImageTag {
            return client.imageURL(itemId: item.id, type: .primary, tag: tag, maxWidth: width)
        }
        if let tag = item.thumbImageTag {
            return client.imageURL(itemId: item.id, type: .thumb, tag: tag, maxWidth: width)
        }
        if let tag = item.firstBackdropTag {
            return client.imageURL(itemId: item.id, type: .backdrop, tag: tag, maxWidth: width, index: 0)
        }
        if let parentId = item.parentThumbItemId, let tag = item.parentThumbImageTag {
            return client.imageURL(itemId: parentId, type: .thumb, tag: tag, maxWidth: width)
        }
        if let seriesId = item.seriesId, let tag = item.seriesThumbImageTag {
            return client.imageURL(itemId: seriesId, type: .thumb, tag: tag, maxWidth: width)
        }
        if let parentId = item.parentBackdropItemId, let tag = item.parentBackdropImageTags?.first {
            return client.imageURL(itemId: parentId, type: .backdrop, tag: tag, maxWidth: width, index: 0)
        }
        return poster(item, width: width)
    }

    public func backdrop(_ item: BaseItem, width: Int = 1920) -> URL? {
        if let tag = item.firstBackdropTag {
            return client.imageURL(itemId: item.id, type: .backdrop, tag: tag, maxWidth: width, index: 0)
        }
        if let parentId = item.parentBackdropItemId, let tag = item.parentBackdropImageTags?.first {
            return client.imageURL(itemId: parentId, type: .backdrop, tag: tag, maxWidth: width, index: 0)
        }
        if item.isEpisode, let tag = item.primaryImageTag {
            return client.imageURL(itemId: item.id, type: .primary, tag: tag, maxWidth: width)
        }
        return nil
    }

    public func logo(_ item: BaseItem, width: Int = 800) -> URL? {
        if let tag = item.logoImageTag {
            return client.imageURL(itemId: item.id, type: .logo, tag: tag, maxWidth: width)
        }
        if let parentId = item.parentLogoItemId, let tag = item.parentLogoImageTag {
            return client.imageURL(itemId: parentId, type: .logo, tag: tag, maxWidth: width)
        }
        // Series logos are not delivered on episodes; the detail screen loads the series when needed.
        return nil
    }

    public func person(_ person: Person, width: Int = 300) -> URL? {
        guard let id = person.id, let tag = person.primaryImageTag else { return nil }
        return client.imageURL(itemId: id, type: .primary, tag: tag, maxWidth: width)
    }

    public func chapter(_ item: BaseItem, index: Int, tag: String?, width: Int = 480) -> URL? {
        guard let tag else { return nil }
        return client.imageURL(itemId: item.id, type: .chapter, tag: tag, maxWidth: width, index: index)
    }
}
