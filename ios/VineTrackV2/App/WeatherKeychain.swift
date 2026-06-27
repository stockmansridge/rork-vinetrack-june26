import Foundation
import Security

/// Lightweight Keychain helper for Davis WeatherLink credentials.
/// Credentials are stored per device (per user keychain), not synced
/// to vineyard-shared preferences.
nonisolated enum WeatherKeychain {

    private static let service = "com.vinetrack.weather.davis"

    enum CredentialKey: String {
        case apiKey = "davis.apiKey"
        case apiSecret = "davis.apiSecret"
    }

    @discardableResult
    static func set(_ value: String?, for key: CredentialKey) -> Bool {
        guard let value, !value.isEmpty else {
            return delete(key: key)
        }
        guard let data = value.data(using: .utf8) else { return false }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key.rawValue
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: data
        ]
        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess { return true }

        var addQuery = query
        addQuery[kSecValueData as String] = data
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        return addStatus == errSecSuccess
    }

    static func get(_ key: CredentialKey) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key.rawValue,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess,
              let data = result as? Data,
              let str = String(data: data, encoding: .utf8) else {
            return nil
        }
        return str
    }

    @discardableResult
    static func delete(key: CredentialKey) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key.rawValue
        ]
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    static var hasCredentials: Bool {
        guard let key = get(.apiKey), !key.isEmpty,
              let secret = get(.apiSecret), !secret.isEmpty else {
            return false
        }
        return true
    }

    static func clearAll() {
        delete(key: .apiKey)
        delete(key: .apiSecret)
    }
}
