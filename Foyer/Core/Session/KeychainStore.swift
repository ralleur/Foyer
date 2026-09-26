import Foundation
import Security
import FoyerFoundation

protocol SecretStore: Sendable {
    func set(_ value: String, for key: String)
    func get(_ key: String) -> String?
    func delete(_ key: String)
}

/// Generic-password Keychain wrapper. Tokens never touch UserDefaults.
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
            if result != errSecSuccess { Log.error(.jellyfin, "Keychain add failed: \(result)") }
        }
    }

    func get(_ key: String) -> String? {
        var query = baseQuery(key)
        query[kSecReturnData] = true
        query[kSecMatchLimit] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func delete(_ key: String) {
        _ = SecItemDelete(baseQuery(key) as CFDictionary)
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
