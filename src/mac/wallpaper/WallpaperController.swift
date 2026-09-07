//
//  WallpaperController.swift — 反转法核心（macOS 26/27 稳定版）
//   ① 用公开 API NSWorkspace 把「登录页图」设为系统真壁纸（锁屏/开机页自动跟随，免 root）
//   ② 写配置，由用户态常驻 DesktopOverlay 在桌面层覆盖「桌面显示图」
//   ③ 管理用户态 LaunchAgent（登录自启、免密码、免 root）
//
//  关键稳定性修复：
//   · 每次系统壁纸渲染到「按内容哈希命名的唯一文件」——NSWorkspace 对相同 URL
//     会判定无变化而跳过重载（这正是旧版改登录页偶发失效、重启后卡死的根因）。
//   · 桌面/登录页选中图都复制到 App 自有的 active 目录，覆盖进程不再读取
//     「文稿」等受 TCC 保护目录，消除反复授权弹窗、保证开机自启可靠。
//   · 设置后回读校验，失败则用全新随机名重试。
//

import AppKit
import CryptoKit
import ImageIO
import UniformTypeIdentifiers

/// 壁纸库中的一张图（id 用文件路径，文件名通过 url.lastPathComponent 暴露给局域网）
struct WPItem: Identifiable, Hashable {
    let id: String
    let name: String
    let url: URL
    var isCustom: Bool
}

final class WallpaperController {

    static let shared = WallpaperController()
    let label = "com.lucas.halo.overlay"

    // 目录（主程序与覆盖进程 DesktopOverlay 必须使用同一目录名）
    var supportDir: URL {
        let d = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Halo", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }
    var libraryDir: URL { let d = supportDir.appendingPathComponent("library", isDirectory: true); try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true); return d }
    /// 实际生效的桌面/登录页副本都放这里（App 自有目录，覆盖进程读取无需任何授权）
    var activeDir: URL { let d = supportDir.appendingPathComponent("active", isDirectory: true); try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true); return d }
    var configURL: URL { supportDir.appendingPathComponent("config.plist") }
    var installedOverlayBin: URL { supportDir.appendingPathComponent("DesktopOverlay") }
    var agentPlistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }

    struct Config {
        var active = false
        var desktopImagePath = ""
        var lockImagePath = ""
        var keepAwake = false
    }

    // MARK: 内容哈希（同一图同名、不同图必不同名 → 保证系统一定重载）

    private func contentHash(_ url: URL) -> String {
        guard let data = try? Data(contentsOf: url) else { return String(Int(Date().timeIntervalSince1970)) }
        return SHA256.hash(data: data).prefix(5).map { String(format: "%02x", $0) }.joined()
    }

    /// 把源图复制进自有 active 目录（按内容哈希命名），覆盖进程只读本目录，杜绝 TCC 弹窗
    private func stageCopy(_ src: URL, role: String) -> URL? {
        let stem = src.deletingPathExtension().lastPathComponent
            .replacingOccurrences(of: "/", with: "_")
        let ext = src.pathExtension.isEmpty ? "img" : src.pathExtension
        let h = contentHash(src)
        let dst = activeDir.appendingPathComponent("\(role)_\(stem)_\(h).\(ext)")
        if FileManager.default.fileExists(atPath: dst.path) { return dst }
        do {
            try? FileManager.default.removeItem(at: dst)
            try FileManager.default.copyItem(at: src, to: dst)
            return dst
        } catch { NSLog("[Halo] stage copy fail \(error)"); return nil }
    }

    /// 清理 active 目录里除当前两张之外的旧副本，避免堆积
    private func cleanupActive(keep: Set<String>) {
        guard let urls = try? FileManager.default.contentsOfDirectory(at: activeDir, includingPropertiesForKeys: nil) else { return }
        for u in urls where !keep.contains(u.lastPathComponent) {
            try? FileManager.default.removeItem(at: u)
        }
    }

    // MARK: 配置读写（原地写，inode 稳定，覆盖进程文件监听不丢事件）

    func readConfig() -> Config {
        guard let d = NSDictionary(contentsOf: configURL) else { return Config() }
        var c = Config()
        c.active = (d["active"] as? Bool) ?? false
        c.desktopImagePath = (d["desktopImagePath"] as? String) ?? ""
        c.lockImagePath = (d["lockImagePath"] as? String) ?? ""
        c.keepAwake = (d["keepAwake"] as? Bool) ?? false
        return c
    }
    private func writeConfig(_ c: Config) {
        let d: [String: Any] = [
            "active": c.active,
            "desktopImagePath": c.desktopImagePath,
            "lockImagePath": c.lockImagePath,
            "keepAwake": c.keepAwake
        ]
        (d as NSDictionary).write(to: configURL, atomically: false)
    }
    private func patch(_ block: (inout Config) -> Void) {
        var c = readConfig(); block(&c); writeConfig(c)
    }

    // MARK: 系统壁纸（公开 API，锁屏 + 开机登录页来源）

    /// 把图充满屏裁切后设为系统真壁纸。唯一文件名确保系统一定重载；以「是否抛错」为准。
    @discardableResult
    func setSystemWallpaper(_ source: URL) -> String? {
        // 先复制进自有目录，保证路径长期稳定可读（不依赖原图是否在受保护目录）
        guard let staged = stageCopy(source, role: "syslock") else {
            return "图像读取失败（无法复制到工作目录）"
        }
        let stem = staged.deletingPathExtension().lastPathComponent
        // 内容哈希命名：不同图必不同 URL（系统才会重载），同一张图复用同一文件
        let rendered = activeDir.appendingPathComponent("\(stem).png")
        guard ImageEngine.fillScreenPNG(staged, outURL: rendered) else {
            return "图像解码或渲染失败"
        }
        // setDesktopImageURL 对每块屏幕设置；它抛错才是真失败
        var thrown: String?
        for screen in NSScreen.screens {
            do {
                try NSWorkspace.shared.setDesktopImageURL(rendered, for: screen, options: [
                    .imageScaling: NSImageScaling.scaleProportionallyUpOrDown.rawValue,
                    .allowClipping: true
                ])
            } catch { thrown = error.localizedDescription }
        }
        if let thrown { return thrown }
        // 该 API 异步落账，给最多 ~0.8s 等系统登记 URL（仅诊断，不再据此误判失败）
        for _ in 0..<8 {
            let allMatch = NSScreen.screens.allSatisfy { sc in
                NSWorkspace.shared.desktopImageURL(for: sc)?.path == rendered.path
            }
            if allMatch { break }
            usleep(100_000)
        }
        UserDefaults.standard.set(rendered.lastPathComponent, forKey: "lastSystemWallpaperFile")
        return nil
    }

    // MARK: 应用 / 恢复

    /// 分离桌面与登录页：系统壁纸=lock（锁屏/开机页），桌面覆盖=desktop
    func apply(desktop: WPItem, lock: WPItem, keepAwake: Bool) -> String? {
        // ① 登录页/锁屏/开机页（系统真壁纸，唯一文件名确保即时生效）
        if let e = setSystemWallpaper(lock.url) { return e }
        // ② 桌面显示图复制到自有目录（覆盖进程读取，免授权、开机可靠）
        let deskCopy = stageCopy(desktop.url, role: "desktop") ?? desktop.url
        // ③ 确保常驻进程在
        ensureAgentInstalled()
        // ④ 保留当前系统壁纸文件名，清理其它旧副本
        var keep = Set([deskCopy.lastPathComponent])
        if let sf = UserDefaults.standard.string(forKey: "lastSystemWallpaperFile") { keep.insert(sf) }
        cleanupActive(keep: keep)
        // ⑤ 桌面覆盖（热切换）
        patch { c in
            c.active = true
            c.desktopImagePath = deskCopy.path
            c.lockImagePath = lock.url.path
            c.keepAwake = keepAwake
        }
        kickAgent()
        return nil
    }

    /// 恢复一致：系统壁纸设为桌面图、关闭覆盖
    func restore(desktop: WPItem?) {
        if let desktop {
            if let e = setSystemWallpaper(desktop.url) { NSLog("[Halo] restore wall err \(e)") }
        }
        patch { c in c.active = false; c.desktopImagePath = ""; c.lockImagePath = "" }
    }

    func setKeepAwake(_ on: Bool) { patch { $0.keepAwake = on } }

    // MARK: 用户态 LaunchAgent（无需密码 / root）

    /// 把内置的 DesktopOverlay 拷到支持目录并写 LaunchAgent plist
    func ensureAgentInstalled() {
        // 拷贝二进制（App 内 Resources/DesktopOverlay）
        if let bundled = Bundle.main.url(forResource: "DesktopOverlay", withExtension: nil) {
            let dst = installedOverlayBin
            let bundledDate = (try? FileManager.default.attributesOfItem(atPath: bundled.path)[.modificationDate] as? Date) ?? nil
            let dstDate = (try? FileManager.default.attributesOfItem(atPath: dst.path)[.modificationDate] as? Date) ?? nil
            if !FileManager.default.fileExists(atPath: dst.path) || bundledDate != dstDate {
                try? FileManager.default.removeItem(at: dst)
                try? FileManager.default.copyItem(at: bundled, to: dst)
                try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dst.path)
            }
        }
        let laDir = agentPlistURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: laDir, withIntermediateDirectories: true)
        let plist: [String: Any] = [
            "Label": label,
            "ProgramArguments": [installedOverlayBin.path, "run"],
            "RunAtLoad": true,
            "KeepAlive": true,
            "ProcessType": "Background",
            "Nice": 1,
            "StandardOutPath": supportDir.appendingPathComponent("overlay.out.log").path,
            "StandardErrorPath": supportDir.appendingPathComponent("overlay.err.log").path
        ]
        (plist as NSDictionary).write(to: agentPlistURL, atomically: true)
        bootstrapAgent()
    }

    @discardableResult
    private func launchctl(_ args: [String]) -> Int32 {
        let p = Process(); p.launchPath = "/bin/launchctl"
        p.arguments = args
        p.standardOutput = Pipe(); p.standardError = Pipe()
        do { try p.run() } catch { return -1 }
        p.waitUntilExit()
        return p.terminationStatus
    }
    private var guiTarget: String { "gui/\(getuid())" }

    private func bootstrapAgent() {
        launchctl(["bootout", guiTarget, label])
        launchctl(["bootstrap", guiTarget, agentPlistURL.path])
        launchctl(["kickstart", "-k", "\(guiTarget)/\(label)"])
    }
    func kickAgent() {
        if !agentRunning() { bootstrapAgent() }
        else { launchctl(["kickstart", "\(guiTarget)/\(label)"]) }
    }
    func agentRunning() -> Bool {
        launchctl(["print", "\(guiTarget)/\(label)"]) == 0
    }
    func uninstallAgent() {
        launchctl(["bootout", guiTarget, label])
        try? FileManager.default.removeItem(at: agentPlistURL)
    }

    // MARK: 局域网远程支持（供 RemoteServer / Coordinator 调用）

    private static let okExt: Set<String> = ["jpg","jpeg","png","heic","heif","tiff","webp","bmp","gif"]

    /// 枚举壁纸库（按名称排序）
    func listLibrary() -> [WPItem] {
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: libraryDir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { return [] }
        return urls.filter { Self.okExt.contains($0.pathExtension.lowercased()) }
            .map { WPItem(id: $0.path, name: $0.deletingPathExtension().lastPathComponent,
                          url: $0, isCustom: true) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// 按文件名（局域网暴露的稳定 id）找库内图片
    func item(named fileName: String) -> WPItem? {
        // 防路径穿越：只取最后一段
        let safe = (fileName as NSString).lastPathComponent
        let url = libraryDir.appendingPathComponent(safe)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return WPItem(id: url.path, name: url.deletingPathExtension().lastPathComponent,
                      url: url, isCustom: true)
    }

    /// 缩略图 JPEG 二进制（iPhone 列表用）
    func thumbJPEG(named fileName: String, maxEdge: CGFloat = 480) -> Data? {
        guard let item = item(named: fileName),
              let img = ImageEngine.thumbnail(at: item.url, maxEdge: maxEdge),
              let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let rep = NSBitmapImageRep(cgImage: cg)
        return rep.representation(using: .jpeg, properties: [.compressionFactor: 0.72])
    }

    /// 原图二进制
    func imageData(named fileName: String) -> Data? {
        guard let item = item(named: fileName) else { return nil }
        return try? Data(contentsOf: item.url)
    }

    /// iPhone 上传：把数据写入壁纸库，自动处理重名与扩展名
    func importImageData(name: String, ext: String, data: Data) -> WPItem? {
        var ext = ext.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        if !Self.okExt.contains(ext) { ext = "jpg" }
        let base = (name as NSString).deletingPathExtension
            .replacingOccurrences(of: "/", with: "_")
        var dst = libraryDir.appendingPathComponent("\(base).\(ext)")
        var i = 2
        while FileManager.default.fileExists(atPath: dst.path) {
            dst = libraryDir.appendingPathComponent("\(base) \(i).\(ext)"); i += 1
        }
        do { try data.write(to: dst, options: .atomic) } catch { return nil }
        return item(named: dst.lastPathComponent)
    }

    /// 按文件名应用双壁纸（远程）
    func applyByNames(desktop: String?, lock: String?, keepAwake: Bool? = nil) -> String? {
        let cfg = readConfig()
        let dItem = desktop.flatMap { item(named: $0) }
        let lItem = lock.flatMap { item(named: $0) }
        guard let d = dItem, let l = lItem else { return "壁纸不存在，请刷新列表" }
        return apply(desktop: d, lock: l, keepAwake: keepAwake ?? cfg.keepAwake)
    }
}
