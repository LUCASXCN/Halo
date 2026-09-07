//
//  HaloCore.swift — 全局常量、目录、配对码、机器信息、持久化偏好
//

import Foundation
import AppKit

enum HaloCore {
    static let appName = "Halo"
    static let bundleID = "com.lucas.halo"
    static let overlayLabel = "com.lucas.halo.overlay"
    static let version = "1.0.0"

    // MARK: 工作目录（主 App / 覆盖进程 / 服务共用同一目录名）

    static var supportDir: URL = {
        let d = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Halo", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }()

    static var libraryDir: URL = {
        let d = supportDir.appendingPathComponent("library", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true); return d
    }()

    static var activeDir: URL = {
        let d = supportDir.appendingPathComponent("active", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true); return d
    }()

    static var configURL: URL { supportDir.appendingPathComponent("config.plist") }
    static var prefsURL: URL { supportDir.appendingPathComponent("halo-prefs.plist") }

    // MARK: 机器信息

    static var macName: String {
        Host.current().localizedName ?? (ProcessInfo.processInfo.hostName.replacingOccurrences(of: ".local", with: ""))
    }

    static var macModel: String {
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        var model = [CChar](repeating: 0, count: size)
        sysctlbyname("hw.model", &model, &size, nil, 0)
        return String(cString: model)
    }

    /// 本机所有 IPv4 地址（供 iPhone 无法用 Bonjour 时手动连接）
    static var ipv4Addresses: [String] {
        var out: [String] = []
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return out }
        defer { freeifaddrs(ifaddr) }
        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let iface = ptr.pointee
            let flags = Int32(iface.ifa_flags)
            guard (flags & IFF_UP) == IFF_UP, (flags & IFF_LOOPBACK) == 0 else { continue }
            guard let sa = iface.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET) else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(sa, socklen_t(sa.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                out.append(String(cString: host))
            }
        }
        return out
    }
}

// MARK: - 持久化偏好（独立 plist，避免与 UserDefaults 域耦合，便于两端一致读写）

final class HaloStore {
    static let shared = HaloStore()
    private var backing: NSMutableDictionary
    private let url = HaloCore.prefsURL

    private init() {
        backing = NSMutableDictionary(contentsOf: url) ?? NSMutableDictionary()
    }

    private func persist() {
        // 原地写，inode 稳定（覆盖进程对 config.plist 的文件监听同理）
        backing.write(to: url, atomically: false)
    }

    func bool(_ key: String, _ def: Bool = false) -> Bool {
        if let v = backing[key] as? Bool { return v }
        return def
    }
    func int(_ key: String, _ def: Int = 0) -> Int {
        if let v = backing[key] as? Int { return v }
        return def
    }
    func double(_ key: String, _ def: Double = 0) -> Double {
        if let v = backing[key] as? Double { return v }
        return def
    }
    func string(_ key: String) -> String? { backing[key] as? String }

    func set(_ key: String, _ value: Any?) {
        if let value { backing[key] = value } else { backing.removeObject(forKey: key) }
        persist()
    }

    // MARK: 语义化字段

    /// 6 位局域网配对码（首次随机，可在界面重置）
    var pairCode: String {
        if let s = string("pairCode"), s.count == 6 { return s }
        let code = String(format: "%06d", Int.random(in: 0...999999))
        set("pairCode", code)
        return code
    }
    func regeneratePairCode() -> String {
        let code = String(format: "%06d", Int.random(in: 0...999999))
        set("pairCode", code); return code
    }

    var remoteEnabled: Bool { get { bool("remoteEnabled", true) } set { set("remoteEnabled", newValue) } }
    var menuBarOnlyOnClose: Bool { get { bool("menuBarOnlyOnClose", true) } set { set("menuBarOnlyOnClose", newValue) } }

    func loadProximity() -> ProximityConfig {
        var c = ProximityConfig()
        c.enabled = bool("px.enabled", false)
        c.autoLock = bool("px.autoLock", true)
        c.autoUnlock = bool("px.autoUnlock", true)
        c.awayRSSI = int("px.away", -70)
        c.nearRSSI = int("px.near", -55)
        c.dwellSeconds = double("px.dwell", 2.5)
        c.peripheralUUID = string("px.uuid") ?? ""
        c.peripheralName = string("px.name") ?? ""
        return c
    }
    func saveProximity(_ c: ProximityConfig) {
        set("px.enabled", c.enabled); set("px.autoLock", c.autoLock); set("px.autoUnlock", c.autoUnlock)
        set("px.away", c.awayRSSI); set("px.near", c.nearRSSI); set("px.dwell", c.dwellSeconds)
        set("px.uuid", c.peripheralUUID); set("px.name", c.peripheralName)
    }
}
