import Foundation
import Security
import FoyerFoundation

protocol SecretStore: Sendable {
    func set(_ value: String, for key: String)
    func get(_ key: String) -> String?
    func delete(_ key: String)
}

/// Generic-password Keychain wrapper. Tokens never touch UserDefaults.
///
/// Unsigned simulator builds (no entitlements, e.g. `xcodebuild … CODE_SIGNING_ALLOWED=NO`) get
/// `errSecMissingEntitlement` from the Keychain; there — and only there — tokens fall back to a
/// file in the simulator's app container so sessions survive relaunches during development.
struct KeychainStore: SecretStore {
    private let service = "app.foyer.tv.credentials"

    func set(_ value: String, for key: String) {
        let data = Data(value.utf8)
        var query = baseQuery(key)
        let status = SecItemCopyMatching(query as CFDictionary, nil)
        if status == errSecSuccess {
            let update: [CFString: Any] = [kSecValueData: data]
            let result = SecItemUpdate(query as CFDictionary, update as CFDictionary)
            if result != errSecSuccess { Log.error(.jellyfin, "Keychain update failed: \(result)") }
        } else {
            query[kSecValueData] = data
            query[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlock
            let result = SecItemAdd(query as CFDictionary, nil)
            if result == errSecMissingEntitlement, let fallback = SimulatorSecretFile.shared {
                Log.warning(.jellyfin, "Keychain unavailable in this unsigned simulator build; using the simulator fallback store")
                fallback.set(value, for: key)
            } else if result != errSecSuccess {
                Log.error(.jellyfin, "Keychain add failed: \(result)")
            }
        }
    }

    func get(_ key: String) -> String? {
        var query = baseQuery(key)
        query[kSecReturnData] = true
        query[kSecMatchLimit] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecSuccess, let data = item as? Data {
            return String(data: data, encoding: .utf8)
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
