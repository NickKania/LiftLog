import Foundation
import Security

/// One Keychain item makes replacement of rotating credentials and registration metadata atomic.
final class ChatGPTKeychainStorage: ChatGPTCredentialStorage {
    private let service = "com.liftlog.app.chatgpt.oauth"
    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: "accounts-v1",
         kSecAttrSynchronizable as String: false]
    }

    func load() throws -> ChatGPTAuthSnapshot? {
        var query = query
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data,
              let snapshot = try? JSONDecoder().decode(ChatGPTAuthSnapshot.self, from: data) else {
            throw ChatGPTAuthError.secureStorage
        }
        return snapshot
    }

    func save(_ snapshot: ChatGPTAuthSnapshot) throws {
        let data = try JSONEncoder().encode(snapshot)
        let changes: [String: Any] = [kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
        let updated = SecItemUpdate(query as CFDictionary, changes as CFDictionary)
        if updated == errSecItemNotFound {
            let added = SecItemAdd(query.merging(changes, uniquingKeysWith: { _, new in new }) as CFDictionary, nil)
            guard added == errSecSuccess else { throw ChatGPTAuthError.secureStorage }
        } else if updated != errSecSuccess { throw ChatGPTAuthError.secureStorage }
    }
}

/// UI test launches never read or write the user's Keychain.
final class ChatGPTMemoryStorage: ChatGPTCredentialStorage {
    private var snapshot: ChatGPTAuthSnapshot?
    func load() throws -> ChatGPTAuthSnapshot? { snapshot }
    func save(_ snapshot: ChatGPTAuthSnapshot) throws { self.snapshot = snapshot }
}
