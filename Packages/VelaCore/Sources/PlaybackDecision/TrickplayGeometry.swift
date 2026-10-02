import Foundation
import JellyfinKit

/// Maps a playback position to a tile image and the crop rectangle inside it.
public struct TrickplayGeometry: Sendable, Hashable {
    public let info: TrickplayInfo
    public let width: Int

    public init(info: TrickplayInfo, width: Int) {
        self.info = info
        self.width = width
    }

    public struct Tile: Sendable, Hashable {
        public let imageIndex: Int
        /// Crop rectangle in pixels within the tile image.
        public let x: Int
        public let y: Int
        public let width: Int
        public let height: Int
    }

    public var thumbnailsPerImage: Int { max(1, info.tileWidth * info.tileHeight) }
    public var imageCount: Int { Int((Double(info.thumbnailCount) / Double(thumbnailsPerImage)).rounded(.up)) }

    public func tile(at position: TimeInterval) -> Tile? {
        guard info.interval > 0, info.thumbnailCount > 0, info.width > 0, info.height > 0 else { return nil }
        let index = min(max(Int(position * 1000 / Double(info.interval)), 0), info.thumbnailCount - 1)
        let imageIndex = index / thumbnailsPerImage
        let within = index % thumbnailsPerImage
        let row = within / max(info.tileWidth, 1)
        let column = within % max(info.tileWidth, 1)
        return Tile(imageIndex: imageIndex, x: column * info.width, y: row * info.height, width: info.width, height: info.height)
    }

    /// Chooses the tile resolution closest to (but preferring at least) the requested display width.
    public static func bestVariant(from variants: [String: TrickplayInfo], preferredWidth: Int) -> (width: Int, info: TrickplayInfo)? {
        let parsed = variants.compactMap { key, value -> (Int, TrickplayInfo)? in
            guard let w = Int(key) else { return nil }
            return (w, value)
        }.sorted { $0.0 < $1.0 }
        guard !parsed.isEmpty else { return nil }
        if let atLeast = parsed.first(where: { $0.0 >= preferredWidth }) { return (atLeast.0, atLeast.1) }
        let largest = parsed[parsed.count - 1]
        return (largest.0, largest.1)
    }
}
