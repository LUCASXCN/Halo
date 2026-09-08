//
//  Protocol.swift — Halo Mac ↔ iPhone 共享契约（纯 Foundation，macOS / iOS 共编同一份）
//  ═══════════════════════════════════════════════════════════════════════════
//  局域网走极简 HTTP/JSON（NWListener / URLSession），蓝牙走自定义 BLE Service。
//  两端都编译本文件，从根上避免「两端字段不一致」。
//

import Foundation

// MARK: - 全局常量

enum Halo {
    /// Bonjour 服务类型（局域网自动发现）
    static let bonjourType = "_halo._tcp"
    static let bonjourDomain = "local."
    /// 默认监听端口（可被系统自动分配；真实端口以 Bonjour 广播为准）
    static let defaultPort: UInt16 = 48631
    /// 配对请求头（值为 Mac 端显示的 6 位配对码）
    static let pairHeader = "X-Halo-Code"
    static let apiVersion = 1

    // 自定义 BLE Service：iPhone 外设广播、Mac 中央扫描连接后测 RSSI 判距离
    // 固定 128-bit UUID（必须全部为十六进制 0-9A-F，否则 CBUUID 会直接抛异常崩溃）
    // 末段 48414C4F 即 "HALO" 的 ASCII，十六进制合法且保留品牌含义。
    static let bleService = "F4B10001-4A52-8F00-0000-48414C4F0001"
    static let bleServiceUUID = bleService.replacingOccurrences(of: "-", with: "")
    /// 保活特征（读/通知，内容无意义，仅用于维持连接、让 RSSI 持续刷新）
    static let bleKeepChar = "F4B10002-4A52-8F00-0000-48414C4F0001"
}

#if canImport(CoreBluetooth)
import CoreBluetooth
extension CBUUID {
    /// 安全构造：CBUUID(string:) 遇到非十六进制字符会抛 NSException 直接导致进程崩溃，
    /// 且 Swift 的 do-catch 无法捕获 ObjC 异常。这里先做格式校验，非法时回退到编译期
    /// 确定合法的固定 Service，从根上保证「任何情况下都不会因 UUID 崩溃」。
    static func halo(_ s: String) -> CBUUID {
        let hex = s.replacingOccurrences(of: "-", with: "")
        let isHex = hex.allSatisfy { $0.isHexDigit }
        let ok128 = hex.count == 32 && isHex
        let ok16  = hex.count == 4 && isHex
        if ok128 || ok16 { return CBUUID(string: s) }
        return CBUUID(string: Halo.bleService)
    }
}
#endif

// MARK: - 枚举与基础模型

enum SlotKind: String, Codable { case desktop, lock }

struct WallpaperInfo: Codable, Identifiable, Hashable {
    var id: String          // 用文件名做稳定 id
    var name: String
    var ext: String
    var thumbPath: String   // 相对请求路径 /thumb/<id>
}

struct ProximityConfig: Codable, Equatable {
    var enabled = false         // 总开关（蓝牙靠近联动）
    var autoLock = true         // 远离自动锁屏
    var autoUnlock = true       // 靠近自动输入密码解锁
    /// 远离阈值：RSSI 低于该值（更负=更远）判定离开，默认 -70
    var awayRSSI: Int = -70
    /// 靠近阈值：RSSI 高于该值判定接近，默认 -55
    var nearRSSI: Int = -55
    /// 连续满足多少秒才触发（防抖）
    var dwellSeconds: Double = 2.5
    /// 延迟锁定：超过远离阈值后等待多少秒才锁屏（5/10/15/30），同时也是断开后的宽限期
    var lockDelay: Int = 10
    /// 目标外设标识符（Mac 记住已配对的 iPhone）
    var peripheralUUID: String = ""
    var peripheralName: String = ""

    /// 容错：把越界/自相矛盾的阈值拉回合法区间，避免坏配置导致误锁/无法解锁
    mutating func normalize() {
        awayRSSI = min(max(awayRSSI, -100), -40)
        nearRSSI = min(max(nearRSSI, -90), -30)
        // near 必须严格大于 away（靠近阈值没那么负）；颠倒则回退默认
        if nearRSSI <= awayRSSI { awayRSSI = -70; nearRSSI = -55 }
        dwellSeconds = min(max(dwellSeconds, 0.5), 30)
        lockDelay = min(max(lockDelay, 3), 60)
    }
}

struct BLEStateInfo: Codable, Equatable {
    var powered = false
    var scanning = false
    var connected = false
    var deviceName: String = ""
    var rssi: Int = 0
    /// close / near / far / searching
    var zone: String = "searching"
}

// MARK: - 响应：/ping  /status

struct PingResponse: Codable {
    var api: Int
    var name: String         // Mac 名称
    var model: String
    var version: String
    var locked: Bool
    var hasPassword: Bool
    var overlayRunning: Bool
    var ble: BLEStateInfo
    var proximity: ProximityConfig
}

struct StatusResponse: Codable {
    var ping: PingResponse
    var wallpapers: [WallpaperInfo]
    var desktopID: String?
    var lockID: String?
    var active: Bool
    var pairRequired: Bool
}

// MARK: - 请求体

struct ApplyRequest: Codable {
    var desktopID: String?
    var lockID: String?
}

struct SetSlotRequest: Codable {
    var slot: SlotKind
    var id: String
}

struct UploadRequest: Codable {
    var name: String
    var ext: String          // jpg / png / heic ...
    var dataBase64: String
    var assignTo: SlotKind?  // 上传后直接指派到某槽位（可选）
}

struct UploadResponse: Codable {
    var ok: Bool
    var wallpaper: WallpaperInfo?
    var error: String?
}

struct LockRequest: Codable { var confirm: Bool? }

struct SimpleResult: Codable {
    var ok: Bool
    var error: String? = nil
    init(ok: Bool, error: String? = nil) { self.ok = ok; self.error = error }
}

// MARK: - 路径与编解码辅助

enum HaloRoute {
    static let ping = "/ping"
    static let status = "/status"
    static let thumb = "/thumb/"       // +id
    static let image = "/image/"       // +id
    static let lock = "/lock"
    static let unlock = "/unlock"
    static let apply = "/apply"
    static let setSlot = "/set-slot"
    static let upload = "/upload"
    static let proximityGet = "/proximity"
    static let proximitySet = "/proximity"
}

enum HaloJSON {
    static let encoder: JSONEncoder = {
        let e = JSONEncoder(); e.outputFormatting = [.sortedKeys]; return e
    }()
    static let decoder = JSONDecoder()

    static func decode<T: Decodable>(_ type: T.Type, from data: Data) -> T? {
        try? decoder.decode(type, from: data)
    }
    static func encode<T: Encodable>(_ value: T) -> Data? {
        try? encoder.encode(value)
    }
}
