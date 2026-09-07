//
//  Keychain.swift — 登录密码安全存取（自动解锁用）。仅存本地钥匙串，绝不上传、不出局域网。
//

import Foundation
import Security

enum Keychain {
    private static let service = HaloCore.bundleID + ".login"
    private static let account = "auto-unlock-password"

    @discardableResult
    static func save(password: String) -> Bool {
        guard let data = password.data(using: .utf8) else { return false }
        // 先删后写，保证更新
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrService as String: service,
                                kSecAttrAccount as String: account]
        SecItemDelete(q as CFDictionary)
        var add = q
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let st = SecItemAdd(add as CFDictionary, nil)
        return st == errSecSuccess
    }

    static func read() -> String? {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let s = String(data: data, encoding: .utf8), !s.isEmpty else { return nil }
        return s
    }

    static var hasPassword: Bool { read() != nil }

    @discardableResult
    static func clear() -> Bool {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrService as String: service,
                                kSecAttrAccount as String: account]
        return SecItemDelete(q as CFDictionary) == errSecSuccess
    }
}
