import Foundation
import TopShelfKit

/// The App Group shared by Vela and its Top Shelf extension (entitlement in both targets).
enum AppGroup {
    static let identifier = "group.com.ralleur.vela"

    /// nil in builds without the entitlement (unsigned simulator builds).
    static var containerURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: identifier)
    }

    /// nil without the entitlement, so unsigned builds never write into their own defaults by mistake.
    static var topShelfStore: TopShelfStore? {
        guard containerURL != nil, let defaults = UserDefaults(suiteName: identifier) else { return nil }
        return TopShelfStore(defaults: defaults)
    }
}
