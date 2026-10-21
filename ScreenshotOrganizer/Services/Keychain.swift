import Foundation
import Security

/// Minimal Keychain wrapper for the TypeSafe API key.
enum Keychain {
    private static let service = "com.lrendina.ScreenshotOrganizer"

    /// The stored API key. Debug builds fall back to the `TYPESAFE_API_KEY` launch environment
    /// variable (`SIMCTL_CHILD_TYPESAFE_API_KEY` with `simctl launch`).
    static var apiKey: String? {
        if let stored = get(SettingsKey.apiKey), !stored.isEmpty { return stored }
        #if DEBUG
        if let env = ProcessInfo.processInfo.environment["TYPESAFE_API_KEY"], !env.isEmpty { return env }
        #endif
        return nil
    }

    static func get(_ account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func set(_ value: String?, for account: String) {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(base as CFDictionary)
        guard let value, !value.isEmpty else { return }
        var add = base
        add[kSecValueData as String] = Data(value.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(add as CFDictionary, nil)
    }
}
