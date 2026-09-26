import Foundation
import UIKit
import ImageIO
import FoyerFoundation

/// Loads, downsamples and caches remote images.
///
/// - Memory: NSCache bounded by decoded byte size (evicted under pressure).
/// - Disk: URLCache in the Caches directory (purgeable by the system).
/// - Requests for the same URL+size are coalesced; cancellation propagates.
final class ImagePipeline: @unchecked Sendable {
    private let memory = NSCache<NSString, UIImage>()
    private let session: URLSession
    private let lock = NSLock()
    private var inflight: [String: Task<UIImage, Error>] = [:]
    /// Provides the MediaBrowser authorization header for image requests (read on the main actor).
    var authorizationHeaderProvider: (@MainActor @Sendable () -> String?)?

    init(memoryLimitBytes: Int = 120 * 1024 * 1024, diskLimitBytes: Int = 600 * 1024 * 1024) {
        memory.totalCostLimit = memoryLimitBytes
        memory.countLimit = 1500
        let cacheDirectory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("Images", isDirectory: true)
        let cache = URLCache(memoryCapacity: 8 * 1024 * 1024, diskCapacity: diskLimitBytes, directory: cacheDirectory)
        let configuration = URLSessionConfiguration.default
        configuration.urlCache = cache
        configuration.requestCachePolicy = .returnCacheDataElseLoad
        configuration.httpMaximumConnectionsPerHost = 6
        configuration.timeoutIntervalForRequest = 20
        session = URLSession(configuration: configuration)
    }

    func image(for url: URL, targetSize: CGSize) async throws -> UIImage {
        let key = cacheKey(url, targetSize)
        if let cached = memory.object(forKey: key as NSString) {
            return cached
        }
        let task = loadTask(for: url, key: key, targetSize: targetSize)
        defer { finishInflight(key) }
        let image = try await task.value
        memory.setObject(image, forKey: key as NSString, cost: Self.cost(of: image))
        return image
    }

    /// Returns the in-flight task for this key or starts one. Synchronous so the lock never spans an await.
    private func loadTask(for url: URL, key: String, targetSize: CGSize) -> Task<UIImage, Error> {
        lock.lock()
        defer { lock.unlock() }
        if let existing = inflight[key] { return existing }
        let created = Task<UIImage, Error>(priority: .userInitiated) { [session, authorizationHeaderProvider] in
            var request = URLRequest(url: url)
            if let authorizationHeaderProvider, let header = await authorizationHeaderProvider() {
                request.setValue(header, forHTTPHeaderField: "Authorization")
            }
            let (data, response) = try await session.data(for: request)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                throw FoyerError(.notFound, detail: "Image HTTP \(http.statusCode)")
            }
            try Task.checkCancellation()
            guard let image = ImagePipeline.downsample(data, to: targetSize) else {
                throw FoyerError(.unknown, detail: "Image decode failed")
            }
            return image
        }
        inflight[key] = created
        return created
    }

    private func finishInflight(_ key: String) {
        lock.lock()
        inflight[key] = nil
        lock.unlock()
    }

    func cachedImage(for url: URL, targetSize: CGSize) -> UIImage? {
        memory.object(forKey: cacheKey(url, targetSize) as NSString)
    }

    func prefetch(_ urls: [URL], targetSize: CGSize) {
        for url in urls.prefix(24) {
            Task(priority: .utility) { _ = try? await image(for: url, targetSize: targetSize) }
        }
    }

    func clearCaches() {
        memory.removeAllObjects()
        session.configuration.urlCache?.removeAllCachedResponses()
        Log.info(.cache, "Image caches cleared")
    }

    var diskUsageBytes: Int { session.configuration.urlCache?.currentDiskUsage ?? 0 }

    private func cacheKey(_ url: URL, _ size: CGSize) -> String {
        "\(url.absoluteString)#\(Int(size.width))x\(Int(size.height))"
    }

    private static func cost(of image: UIImage) -> Int {
        guard let cg = image.cgImage else { return 1 }
        return cg.bytesPerRow * cg.height
    }

    /// Decodes at most the requested pixel size (accounting for the screen scale), which keeps
    /// memory proportional to what is on screen rather than to the source file.
    static func downsample(_ data: Data, to size: CGSize) -> UIImage? {
        let scale = UITraitCollection.current.displayScale > 0 ? UITraitCollection.current.displayScale : 1
        let maxPixel = max(size.width, size.height) * scale
        let options: [CFString: Any] = [kCGImageSourceShouldCache: false]
        guard let source = CGImageSourceCreateWithData(data as CFData, options as CFDictionary) else { return nil }
        let thumbnailOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel > 0 ? maxPixel : 1920,
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions as CFDictionary) else {
            return UIImage(data: data)
        }
        return UIImage(cgImage: cgImage, scale: scale, orientation: .up)
    }
}
