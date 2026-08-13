import Foundation
import Security

/// Keychain 极简封装（Security/SecItem*，无第三方依赖）。
/// 只存字符串密钥类数据（API Secret / Key），绝不落配置文件。
enum KeychainStore {
    private static let service = "me.ckai.translate"

    static func set(_ value: String, for key: KeychainKey) {
        delete(key)
        guard !value.isEmpty, let data = value.data(using: .utf8) else { return }
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: key.rawValue,
            kSecValueData: data,
        ]
        SecItemAdd(query as CFDictionary, nil)
    }

    static func get(_ key: KeychainKey) -> String? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: key.rawValue,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func delete(_ key: KeychainKey) {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: key.rawValue,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
