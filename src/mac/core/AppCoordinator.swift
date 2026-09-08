//
//  AppCoordinator.swift — 中枢：串联壁纸、锁屏、蓝牙邻近、局域网服务，对外提供统一状态
//

import Foundation
import Combine
import AppKit
import UserNotifications
import ServiceManagement
import ApplicationServices

final class AppCoordinator: ObservableObject, HaloServerDatasource {
    static let shared = AppCoordinator()

    let wallpapers = WallpaperController.shared
    let proximity = ProximityLock.shared
    let locker = ScreenLocker.shared
    let server = RemoteServer.shared

    @Published var locked = false
    @Published var hasPassword = false
    @Published var overlayRunning = false
    @Published var selectedDesktopFile: String?
    @Published var selectedLockFile: String?
    /// 开机自启动（SMAppService，macOS 13+）
    var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            do {
                if newValue {
                    if SMAppService.mainApp.status != .enabled {
                        try SMAppService.mainApp.register()
                    }
                } else {
                    if SMAppService.mainApp.status == .enabled {
                        try SMAppService.mainApp.unregister()
                    }
                }
            } catch {
                NSLog("[Halo] 自启动设置失败: \(error)")
            }
        }
    }

    private var bag = Set<AnyCancellable>()
    private var started = false

    private init() {}

    func boot() {
        guard !started else { return }
        started = true
        // 预加载钥匙串缓存（启动时未锁屏，避免锁屏时访问钥匙串阻塞导致解锁失败）
        Keychain.preload()
        locked = locker.isLocked

        // 检测辅助功能权限（自动解锁需要 CGEvent 投递密码到 loginwindow，必须有此权限）
        // 无权限时事件会被 WindowServer 静默拦截，不会投递到 loginwindow
        if !AXIsProcessTrusted() {
            DispatchQueue.main.async {
                let alert = NSAlert()
                alert.messageText = "Halo 需要辅助功能权限"
                alert.informativeText = "自动解锁功能需要模拟键盘输入密码到登录窗口。请在「系统设置 → 隐私与安全性 → 辅助功能」中添加并启用 Halo。\n\n授权后请重启 Halo。"
                alert.addButton(withTitle: "打开系统设置")
                alert.addButton(withTitle: "稍后")
                if alert.runModal() == .alertFirstButtonReturn {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                        NSWorkspace.shared.open(url)
                    }
                }
            }
        }
        selectedDesktopFile = HaloStore.shared.string("sel.desktop")
        selectedLockFile = HaloStore.shared.string("sel.lock")

        locker.onLockStateChange = { [weak self] l in
            self?.locked = l
            if !l {
                DispatchQueue.global(qos: .userInitiated).async {
                    let has = Keychain.hasPassword
                    DispatchQueue.main.async { self?.hasPassword = has }
                }
            }
        }
        locker.startObserving()
        proximity.start()

        server.datasource = self
        if HaloStore.shared.remoteEnabled { server.start() }

        // 请求通知权限（信号丢失、自动解锁失败等需要发通知）
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }

        // 钥匙串读取可能触发系统授权弹窗（ad-hoc 重签后授权会重置），
        // 必须放后台异步，绝不能阻塞主线程 —— 否则 server.start() / 菜单栏都不会执行。
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let has = Keychain.hasPassword
            DispatchQueue.main.async { self?.hasPassword = has }
        }

        // 周期性刷新覆盖进程状态
        Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            self?.overlayRunning = self?.wallpapers.agentRunning() ?? false
        }
    }

    // MARK: UI 入口

    func lockNow() { locker.lockNow() }

    func setPassword(_ pw: String) {
        if pw.isEmpty { Keychain.clear() } else { Keychain.save(password: pw) }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let has = Keychain.hasPassword
            DispatchQueue.main.async { self?.hasPassword = has }
        }
    }

    func apply(desktop: WPItem, lock: WPItem, keepAwake: Bool) -> String? {
        if let e = wallpapers.apply(desktop: desktop, lock: lock, keepAwake: keepAwake) { return e }
        HaloStore.shared.set("sel.desktop", desktop.url.lastPathComponent)
        HaloStore.shared.set("sel.lock", lock.url.lastPathComponent)
        selectedDesktopFile = desktop.url.lastPathComponent
        selectedLockFile = lock.url.lastPathComponent
        overlayRunning = wallpapers.agentRunning()
        return nil
    }

    // MARK: HaloServerDatasource

    func makePing() -> PingResponse {
        PingResponse(api: Halo.apiVersion,
                     name: HaloCore.macName, model: HaloCore.macModel, version: HaloCore.version,
                     locked: locker.isLocked, hasPassword: hasPassword,
                     overlayRunning: wallpapers.agentRunning(),
                     ble: proximity.state, proximity: proximity.config)
    }

    func makeStatus() -> StatusResponse {
        let list = wallpapers.listLibrary().map {
            WallpaperInfo(id: $0.url.lastPathComponent, name: $0.name,
                          ext: $0.url.pathExtension,
                          thumbPath: HaloRoute.thumb + $0.url.lastPathComponent)
        }
        return StatusResponse(ping: makePing(), wallpapers: list,
                              desktopID: HaloStore.shared.string("sel.desktop"),
                              lockID: HaloStore.shared.string("sel.lock"),
                              active: wallpapers.readConfig().active, pairRequired: true)
    }

    func remoteLock() { locker.lockNow() }

    /// 远程解锁：唤醒显示器 → 等密码框就绪 → 从钥匙串输入密码
    func remoteUnlock() {
        guard locker.isLocked else { return }
        locker.wakeDisplay()
        // 关键：用独立 Thread + usleep，完全不依赖 GCD 队列（锁屏时主队列 runloop 被挂起）
        Thread.detachNewThread { [weak self] in
            Thread.sleep(forTimeInterval: 0.8)
            self?.locker.autoUnlockFromKeychain()
        }
    }

    func remoteApply(desktopID: String?, lockID: String?) -> String? {
        let d = desktopID ?? HaloStore.shared.string("sel.desktop")
        let l = lockID ?? HaloStore.shared.string("sel.lock")
        guard let d, let l else { return "尚未分别选择桌面与登录页壁纸" }
        if let e = wallpapers.applyByNames(desktop: d, lock: l) { return e }
        HaloStore.shared.set("sel.desktop", d); HaloStore.shared.set("sel.lock", l)
        DispatchQueue.main.async { self.selectedDesktopFile = d; self.selectedLockFile = l }
        return nil
    }

    func remoteSetSlot(slot: SlotKind, id: String) -> String? {
        let curD = HaloStore.shared.string("sel.desktop")
        let curL = HaloStore.shared.string("sel.lock")
        var d = curD, l = curL
        switch slot {
        case .desktop: d = id
        case .lock: l = id
        }
        guard d != nil, l != nil else {
            // 另一槽位还没选过：只记录，不强制应用
            HaloStore.shared.set(slot == .desktop ? "sel.desktop" : "sel.lock", id)
            DispatchQueue.main.async {
                if slot == .desktop { self.selectedDesktopFile = id } else { self.selectedLockFile = id }
            }
            return nil
        }
        return remoteApply(desktopID: d, lockID: l)
    }

    func remoteUpload(name: String, ext: String, data: Data, assign: SlotKind?) -> (WallpaperInfo?, String?) {
        guard let item = wallpapers.importImageData(name: name, ext: ext, data: data) else {
            return (nil, "图片保存失败")
        }
        let info = WallpaperInfo(id: item.url.lastPathComponent, name: item.name,
                                 ext: item.url.pathExtension,
                                 thumbPath: HaloRoute.thumb + item.url.lastPathComponent)
        if let slot = assign { _ = remoteSetSlot(slot: slot, id: item.url.lastPathComponent) }
        return (info, nil)
    }

    func remoteThumb(id: String) -> Data? { wallpapers.thumbJPEG(named: id) }
    func remoteImage(id: String) -> Data? { wallpapers.imageData(named: id) }

    func remoteGetProximity() -> ProximityConfig { proximity.config }
    func remoteSetProximity(_ c: ProximityConfig) -> String? {
        var merged = c
        merged.normalize()
        // 设备绑定关系只允许在 Mac 端修改：远程同步不得清空已绑定的 iPhone
        if merged.peripheralUUID.isEmpty {
            merged.peripheralUUID = proximity.config.peripheralUUID
            merged.peripheralName = proximity.config.peripheralName
        }
        proximity.update(merged); return nil
    }
}
