import Foundation
import Security

/// 令牌存钥匙串，不进 UserDefaults。
enum Keychain {
    private static let service = "app.codexpocket.ios"

    static func get(_ key: String) -> String? {
        read(key).value
    }

    static func read(_ key: String) -> (value: String?, status: OSStatus) {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: AnyObject?
        let status = SecItemCopyMatching(q as CFDictionary, &out)
        guard status == errSecSuccess else { return (nil, status) }
        guard let data = out as? Data, let value = String(data: data, encoding: .utf8) else {
            return (nil, errSecDecode)
        }
        return (value, status)
    }

    @discardableResult
    static func set(_ value: String, _ key: String) -> OSStatus {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        guard !value.isEmpty else {
            let status = SecItemDelete(q as CFDictionary)
            return status == errSecItemNotFound ? errSecSuccess : status
        }
        let update = [kSecValueData as String: Data(value.utf8)]
        let status = SecItemUpdate(q as CFDictionary, update as CFDictionary)
        guard status == errSecItemNotFound else { return status }
        var add = q
        add[kSecValueData as String] = Data(value.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        return SecItemAdd(add as CFDictionary, nil)
    }
}
