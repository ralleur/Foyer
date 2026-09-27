import Foundation
import TopShelfKit

/// The App Group shared by Vela and its Top Shelf extension (entitlement in both targets).
enum AppGroup {
    static let identifier = "group.com.ralleur.vela"

    /// nil in builds without the entitlement (unsigned simulator builds).
    static var containerURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: identifier)
    }

    static var topShelfStore: TopShelfStore? {
        containerURL.map { TopShelfStore(directory: $0.appendingPathComponent("Library/Application Support/TopShelf", isDirectory: true)) }
    }
}
