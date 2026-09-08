//
//  Keychain.swift — 登录密码安全存取（自动解锁用）。仅存本地钥匙串，绝不上传、不出局域网。
//  V1.5：加内存缓存，避免 ad-hoc 签名 App 反复触发钥匙串授权弹窗
//

import Foundation
import Security

enum Keychain {
    private static let service = HaloCore.bundleID + ".login"
    private static let account = "auto-unlock-password"
    /// 内存缓存：启动时读一次，后续直接用，避免反复弹钥匙串授权框
    private static var cachedPassword: String?
    private static var cacheLoaded = false

    @discardableResult
    static func save(password: String) -> Bool {
        guard let data = password.data(using: .utf8) else { return false }
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrService as String: service,
                                kSecAttrAccount as String: account]
        SecItemDelete(q as CFDictionary)
        var add = q
        add[kSecValueData as String] = data
        // AfterFirstUnlock：开机后第一次解锁即可访问，锁屏期间也能读（自动解锁需要）
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let st = SecItemAdd(add as CFDictionary, nil)
        if st == errSecSuccess {
            cachedPassword = password
            cacheLoaded = true
        }
        return st == errSecSuccess
    }

    /// 预加载缓存（App 启动时调用，此时未锁屏，避免锁屏时访问钥匙串阻塞）
    static func preload() {
        _ = read()
    }

    static func read() -> String? {
        // 优先用缓存，避免反复访问钥匙串触发授权弹窗
        if cacheLoaded { return cachedPassword }
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
              let s = String(data: data, encoding: .utf8), !s.isEmpty else {
            cacheLoaded = true
            cachedPassword = nil
            return nil
        }
        cachedPassword = s
        cacheLoaded = true
        return s
    }

    static var hasPassword: Bool { read() != nil }

    @discardableResult
    static func clear() -> Bool {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrService as String: service,
                                kSecAttrAccount as String: account]
        let ok = SecItemDelete(q as CFDictionary) == errSecSuccess
        cachedPassword = nil
        cacheLoaded = true
        return ok
    }
}
