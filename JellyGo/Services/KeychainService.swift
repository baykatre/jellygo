import Foundation
import Security

final class KeychainService {
    static let shared = KeychainService()
    private init() {}

    private let tokenKey = "jellygo.auth.token"

    // MARK: - Current Session (legacy key)

    func saveToken(_ token: String) { save(token, forKey: tokenKey) }
    func getToken() -> String? { get(forKey: tokenKey) }
    func deleteToken() { delete(forKey: tokenKey) }

    // MARK: - Per-Account Tokens (keyed by composite accountId = userId@serverURL)

    func saveToken(_ token: String, forAccountId accountId: String) {
        save(token, forKey: "jellygo.token.\(accountId)")
    }

    func getToken(forAccountId accountId: String) -> String? {
        get(forKey: "jellygo.token.\(accountId)")
    }

    func deleteToken(forAccountId accountId: String) {
        delete(forKey: "jellygo.token.\(accountId)")
    }

    // MARK: - Helpers

    private func save(_ value: String, forKey key: String) {
        let data = Data(value.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]
        if SecItemUpdate(query as CFDictionary, attributes as CFDictionary) == errSecItemNotFound {
            var addQuery = query
            addQuery[kSecValueData as String] = data
            addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            SecItemAdd(addQuery as CFDictionary, nil)
        }
    }

    private func get(forKey key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func delete(forKey key: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key
        ]
        SecItemDelete(query as CFDictionary)
    }
}
