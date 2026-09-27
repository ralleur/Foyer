import Foundation
import Security
import VelaFoundation

protocol SecretStore: Sendable {
    func set(_ value: String, for key: String)
    func get(_ key: String) -> String?
    func delete(_ key: String)
}

/// Generic-password Keychain wrapper. Tokens never touch UserDefaults.
///
/// Items live in the App Group's access group so the Top Shelf extension can read the token;
/// tokens saved by older builds (app-only access group) move there the first time they are read.
///
/// Unsigned simulator builds (no entitlements, e.g. `xcodebuild … CODE_SIGNING_ALLOWED=NO`) get
/// `errSecMissingEntitlement` from the Keychain; there — and only there — tokens fall back to a
/// file in the simulator's app container so sessions survive relaunches during development.
struct KeychainStore: SecretStore {
    private let service = "app.vela.tv.credentials"
    var accessGroup: String? = AppGroup.identifier

    func set(_ value: String, for key: String) {
        // Remove the item from whichever access group holds it, then add it to the shared one.
        _ = SecItemDelete(baseQuery(key) as CFDictionary)
        var result = add(value, for: key, accessGroup: accessGroup)
        if result == errSecMissingEntitlement, accessGroup != nil {
            Log.notice(.jellyfin, "Keychain access group \(accessGroup ?? "") unavailable; token stays app-only (no live Top Shelf)")
            result = add(value, for: key, accessGroup: nil)
        }
        if result == errSecMissingEntitlement, let fallback = SimulatorSecretFile.shared {
            Log.warning(.jellyfin, "Keychain unavailable in this unsigned simulator build; using the simulator fallback store")
            fallback.set(value, for: key)
        } else if result != errSecSuccess {
            Log.error(.jellyfin, "Keychain add failed: \(result)")
        }
    }

    /// Copies the item into the shared group first and removes the old copy only once that worked.
    private func migrate(_ value: String, for key: String, from oldGroup: String, to newGroup: String) {
        let result = add(value, for: key, accessGroup: newGroup)
        guard result == errSecSuccess || result == errSecDuplicateItem else {
            Log.notice(.jellyfin, "Token stays in the app-only Keychain group (\(result)); Top Shelf will use the last snapshot")
            return
        }
        var old = baseQuery(key)
        old[kSecAttrAccessGroup] = oldGroup
        _ = SecItemDelete(old as CFDictionary)
        Log.info(.jellyfin, "Moved token \(key) into the shared Keychain access group")
    }

    private func add(_ value: String, for key: String, accessGroup: String?) -> OSStatus {
        var query = baseQuery(key)
        query[kSecValueData] = Data(value.utf8)
        query[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlock
        if let accessGroup { query[kSecAttrAccessGroup] = accessGroup }
        return SecItemAdd(query as CFDictionary, nil)
    }

    func get(_ key: String) -> String? {
        var query = baseQuery(key)
        query[kSecReturnData] = true
        query[kSecReturnAttributes] = true
        query[kSecMatchLimit] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecSuccess, let attributes = item as? [CFString: Any], let data = attributes[kSecValueData] as? Data,
           let value = String(data: data, encoding: .utf8) {
            if let accessGroup, let oldGroup = attributes[kSecAttrAccessGroup] as? String, oldGroup != accessGroup {
                migrate(value, for: key, from: oldGroup, to: accessGroup)
            }
            return value
        }
        return SimulatorSecretFile.shared?.get(key)
    }

    func delete(_ key: String) {
        _ = SecItemDelete(baseQuery(key) as CFDictionary)
        SimulatorSecretFile.shared?.delete(key)
    }

    private func baseQuery(_ key: String) -> [CFString: Any] {
        [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: key,
        ]
    }
}

/// Used by UI tests so nothing is written to the real Keychain.
final class InMemoryKeychain: SecretStore, @unchecked Sendable {
    private var storage: [String: String] = [:]
    private let lock = NSLock()

    func set(_ value: String, for key: String) {
        lock.lock(); storage[key] = value; lock.unlock()
    }

    func get(_ key: String) -> String? {
        lock.lock(); defer { lock.unlock() }; return storage[key]
    }

    func delete(_ key: String) {
        lock.lock(); storage[key] = nil; lock.unlock()
    }
}

/// Simulator-only persistence for unsigned development builds (see `KeychainStore`). Never compiled for devices.
final class SimulatorSecretFile: SecretStore, @unchecked Sendable {
    #if targetEnvironment(simulator)
    static let shared: SimulatorSecretFile? = SimulatorSecretFile()
    #else
    static let shared: SimulatorSecretFile? = nil
    #endif

    private let url: URL
    private let lock = NSLock()

    private init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        url = base.appendingPathComponent("simulator-secrets.json")
    }

    private func load() -> [String: String] {
        (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode([String: String].self, from: $0) } ?? [:]
    }

    private func save(_ dict: [String: String]) {
        if let data = try? JSONEncoder().encode(dict) { try? data.write(to: url, options: .atomic) }
    }

    func set(_ value: String, for key: String) {
        lock.lock(); defer { lock.unlock() }
        var dict = load(); dict[key] = value; save(dict)
    }

    func get(_ key: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        return load()[key]
    }

    func delete(_ key: String) {
        lock.lock(); defer { lock.unlock() }
        var dict = load(); dict[key] = nil; save(dict)
    }
}
