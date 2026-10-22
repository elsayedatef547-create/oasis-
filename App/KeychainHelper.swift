import Foundation
import Security

enum KeychainHelper {
    static let service: String = Bundle.main.bundleIdentifier ?? "com.invoicescanner.app"
    static let apiKeyAccount: String = "gemini_api_key"

    @discardableResult
    static func save(_ value: String, account: String) -> Bool {
        guard let data = value.data(using: .utf8) else { return false }

        let baseQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]

        SecItemDelete(baseQuery as CFDictionary)

        var attributes = baseQuery
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly

        let status = SecItemAdd(attributes as CFDictionary, nil)
        return status == errSecSuccess
    }

    static func read(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: kCFBooleanTrue as Any,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    static func delete(account: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    // MARK: Convenience for the Gemini API key

    @discardableResult
    static func saveAPIKey(_ key: String) -> Bool {
        save(key, account: KeychainHelper.apiKeyAccount)
    }

    static func readAPIKey() -> String? {
        read(account: KeychainHelper.apiKeyAccount)
    }

    @discardableResult
    static func deleteAPIKey() -> Bool {
        delete(account: KeychainHelper.apiKeyAccount)
    }
}
