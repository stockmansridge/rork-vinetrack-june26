import Foundation
import Security

/// Lightweight Keychain helper for biometric-login preference and the
/// last-signed-in email used to label the unlock screen. We never store
/// the user's password — Supabase persists its own refresh token, and
/// biometrics simply gate access to the already-restored session.
nonisolated enum BiometricKeychain {

    private static let service = "com.vinetrack.biometric"

    private enum K: String {
        case enabled = "biometric.enabled"
        case email = "biometric.savedEmail"
    }

    static var isEnabled: Bool {
        (getString(.enabled) ?? "") == "1"
    }

    static var savedEmail: String? {
        getString(.email)
    }

    static func setEnabled(_ value: Bool) {
        setString(value ? "1" : nil, key: .enabled)
    }

    static func setSavedEmail(_ value: String?) {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        setString((trimmed?.isEmpty == false) ? trimmed : nil, key: .email)
    }

    static func clearAll() {
        setEnabled(false)
        setSavedEmail(nil)
    }

    // MARK: - Internals

    private static func setString(_ value: String?, key: K) {
        guard let value, !value.isEmpty else {
            _ = delete(key: key)
            return
        }
        guard let data = value.data(using: .utf8) else { return }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key.rawValue
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: data
        ]
        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess { return }

        var addQuery = query
        addQuery[kSecValueData as String] = data
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        _ = SecItemAdd(addQuery as CFDictionary, nil)
    }

    private static func getString(_ key: K) -> String? {
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
    private static func delete(key: K) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key.rawValue
        ]
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }
}
