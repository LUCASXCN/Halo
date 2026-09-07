//
//  AppCoordinator.swift — 中枢：串联壁纸、锁屏、蓝牙邻近、局域网服务，对外提供统一状态
//

import Foundation
import Combine
import AppKit

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

    private var bag = Set<AnyCancellable>()
    private var started = false

    private init() {}

    func boot() {
        guard !started else { return }
        started = true
        hasPassword = Keychain.hasPassword
        locked = locker.isLocked
        selectedDesktopFile = HaloStore.shared.string("sel.desktop")
        selectedLockFile = HaloStore.shared.string("sel.lock")

        locker.onLockStateChange = { [weak self] l in
            self?.locked = l
            if !l { DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { self?.hasPassword = Keychain.hasPassword } }
        }
        locker.startObserving()
        proximity.start()

        server.datasource = self
        if HaloStore.shared.remoteEnabled { server.start() }

        // 周期性刷新覆盖进程状态
        Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            self?.overlayRunning = self?.wallpapers.agentRunning() ?? false
        }
    }

    // MARK: UI 入口

    func lockNow() { locker.lockNow() }

    func setPassword(_ pw: String) {
        if pw.isEmpty { Keychain.clear() } else { Keychain.save(password: pw) }
        hasPassword = Keychain.hasPassword
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
                     locked: locker.isLocked, hasPassword: Keychain.hasPassword,
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
        proximity.update(c); return nil
    }
}
