import Foundation
import UIKit
import JellyfinKit

enum DeviceInfo {
    private static let deviceIdKey = "vela.deviceId"

    /// Stable per-install identifier shown in the Jellyfin dashboard.
    static var persistentDeviceId: String {
        if let existing = UserDefaults.standard.string(forKey: deviceIdKey) { return existing }
        let fresh = UUID().uuidString
        UserDefaults.standard.set(fresh, forKey: deviceIdKey)
        return fresh
    }

    static var appVersion: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
        return "\(short) (\(build))"
    }

    /// "AppleTV14,1" style identifier.
    static var modelIdentifier: String {
        var systemInfo = utsname()
        uname(&systemInfo)
        let mirror = Mirror(reflecting: systemInfo.machine)
        let identifier = mirror.children.reduce(into: "") { result, element in
            guard let value = element.value as? Int8, value != 0 else { return }
            result.append(String(UnicodeScalar(UInt8(value))))
        }
        return identifier.isEmpty ? "AppleTV" : identifier
    }

    static var isAppleTVHD: Bool { modelIdentifier == "AppleTV5,3" }

    @MainActor
    static var deviceName: String {
        UIDevice.current.name.isEmpty ? "Apple TV" : UIDevice.current.name
    }

    @MainActor
    static func identity() -> DeviceIdentity {
        DeviceIdentity(clientName: "Vela", deviceName: deviceName, deviceId: persistentDeviceId,
                       version: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0")
    }
}
