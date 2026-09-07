//
//  AppModel.swift — 主界面视图模型：壁纸库 + 双图选择 + 邻近/远程/密码设置
//

import AppKit
import SwiftUI
import Combine

final class AppModel: ObservableObject {
    @Published var items: [WPItem] = []
    @Published var desktopID: String?
    @Published var lockID: String?
    @Published var busy = false
    @Published var keepAwake = false
    @Published var overlayRunning = false
    @Published var notice: String?
    @Published var appliedDesktop: String?
    @Published var appliedLock: String?

    // 联动
    @Published var pairCode = ""
    @Published var ipAddresses: [String] = []
    @Published var remoteEnabled = true
    @Published var hasPassword = false
    @Published var passwordField = ""
    @Published var showPassword = false
    @Published var ble = BLEStateInfo()
    @Published var prox = ProximityConfig()
    @Published var pairCandidates: [ProximityLock.DiscoveredDevice] = []

    let coord = AppCoordinator.shared
    private var ctrl: WallpaperController { coord.wallpapers }
    private var thumbCache = NSCache<NSString, NSImage>()
    private var bag = Set<AnyCancellable>()

    func start() {
        loadLibrary()
        loadPrefs()
        keepAwake = ctrl.readConfig().keepAwake
        overlayRunning = ctrl.agentRunning()
        pairCode = HaloStore.shared.pairCode
        ipAddresses = HaloCore.ipv4Addresses
        remoteEnabled = HaloStore.shared.remoteEnabled
        hasPassword = Keychain.hasPassword
        prox = coord.proximity.config

        coord.proximity.$state.receive(on: DispatchQueue.main).sink { [weak self] in self?.ble = $0 }.store(in: &bag)
        coord.proximity.$config.receive(on: DispatchQueue.main).sink { [weak self] in self?.prox = $0 }.store(in: &bag)
        coord.proximity.$pairCandidates.receive(on: DispatchQueue.main).sink { [weak self] in self?.pairCandidates = $0 }.store(in: &bag)
        coord.$overlayRunning.receive(on: DispatchQueue.main).sink { [weak self] in self?.overlayRunning = $0 }.store(in: &bag)

        Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.overlayRunning = self.ctrl.agentRunning()
            self.hasPassword = Keychain.hasPassword
            // 远程/外部改动后，让本地选中态跟随权威选择
            if let f = self.coord.selectedDesktopFile,
               let it = self.items.first(where: { $0.url.lastPathComponent == f }) { self.desktopID = it.id }
            if let f = self.coord.selectedLockFile,
               let it = self.items.first(where: { $0.url.lastPathComponent == f }) { self.lockID = it.id }
        }
    }

    private func loadPrefs() {
        let d = UserDefaults.standard
        let selD = HaloStore.shared.string("sel.desktop")
        let selL = HaloStore.shared.string("sel.lock")
        desktopID = d.string(forKey: "desktopID") ?? items.first { $0.url.lastPathComponent == selD }?.id
        lockID = d.string(forKey: "lockID") ?? items.first { $0.url.lastPathComponent == selL }?.id
        if let ad = d.string(forKey: "appliedDesktop") { appliedDesktop = ad }
        if let al = d.string(forKey: "appliedLock") { appliedLock = al }
        if desktopID == nil || !items.contains(where: { $0.id == desktopID }) { desktopID = items.first?.id }
        if lockID == nil || !items.contains(where: { $0.id == lockID }) { lockID = items.first?.id }
    }

    // MARK: 壁纸库

    private static let migrationKey = "didMigrateLegacyWallpaperFolder"

    func loadLibrary() {
        migrateLegacyFolderIfNeeded()
        items = ctrl.listLibrary()
    }

    private func migrateLegacyFolderIfNeeded() {
        let d = UserDefaults.standard
        guard !d.bool(forKey: Self.migrationKey) else { return }
        d.set(true, forKey: Self.migrationKey)
        let legacy = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("壁纸")
        guard let urls = try? FileManager.default.contentsOfDirectory(at: legacy, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { return }
        for src in urls {
            let dst = ctrl.libraryDir.appendingPathComponent(src.lastPathComponent)
            if !FileManager.default.fileExists(atPath: dst.path) { try? FileManager.default.copyItem(at: src, to: dst) }
        }
    }

    @discardableResult
    func importURLs(_ srcURLs: [URL]) -> Int {
        var n = 0
        for src in srcURLs {
            var dst = ctrl.libraryDir.appendingPathComponent(src.lastPathComponent)
            if FileManager.default.fileExists(atPath: dst.path) {
                let base = src.deletingPathExtension().lastPathComponent, ext = src.pathExtension
                var i = 2
                while FileManager.default.fileExists(atPath: dst.path) {
                    dst = ctrl.libraryDir.appendingPathComponent("\(base) \(i).\(ext)"); i += 1
                }
            }
            do { try FileManager.default.copyItem(at: src, to: dst); n += 1 }
            catch { notice = "导入失败：\(error.localizedDescription)" }
        }
        guard n > 0 else { return 0 }
        loadLibrary()
        notice = "已添加 \(n) 张"
        return n
    }

    func importImage() {
        let panel = NSOpenPanel()
        panel.title = "选择图片（可多选、任意位置）"
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        importURLs(panel.urls)
    }

    var desktopItem: WPItem? { items.first { $0.id == desktopID } }
    var lockItem: WPItem? { items.first { $0.id == lockID } }

    func thumbnail(_ item: WPItem, edge: CGFloat) -> NSImage? {
        let key = "\(item.id)#\(Int(edge))" as NSString
        if let c = thumbCache.object(forKey: key) { return c }
        guard let img = ImageEngine.thumbnail(at: item.url, maxEdge: edge) else { return nil }
        thumbCache.setObject(img, forKey: key); return img
    }

    // MARK: 应用 / 恢复

    func applyAll() {
        guard let d = desktopItem, let l = lockItem else { notice = "请分别选择桌面与登录页壁纸"; return }
        busy = true
        DispatchQueue.global(qos: .userInitiated).async {
            let err = self.coord.apply(desktop: d, lock: l, keepAwake: self.keepAwake)
            DispatchQueue.main.async {
                self.busy = false
                if let err { self.notice = "应用失败：\(err)"; return }
                UserDefaults.standard.set(d.id, forKey: "desktopID")
                UserDefaults.standard.set(l.id, forKey: "lockID")
                UserDefaults.standard.set(d.name, forKey: "appliedDesktop")
                UserDefaults.standard.set(l.name, forKey: "appliedLock")
                self.appliedDesktop = d.name; self.appliedLock = l.name
                self.overlayRunning = self.ctrl.agentRunning()
                self.notice = "已应用：桌面「\(d.name)」· 登录页「\(l.name)」"
            }
        }
    }

    func restoreDefault() {
        confirm(text: "恢复为桌面与登录页一致？", info: "将关闭桌面覆盖，登录页重新跟随桌面壁纸。") {
            self.busy = true
            DispatchQueue.global(qos: .userInitiated).async {
                self.ctrl.restore(desktop: self.desktopItem)
                DispatchQueue.main.async {
                    self.busy = false; self.appliedDesktop = nil; self.appliedLock = nil
                    UserDefaults.standard.removeObject(forKey: "appliedDesktop")
                    UserDefaults.standard.removeObject(forKey: "appliedLock")
                    self.notice = "已恢复：登录页跟随桌面壁纸"
                }
            }
        }
    }

    func setKeepAwake(_ on: Bool) {
        keepAwake = on; ctrl.setKeepAwake(on)
        notice = on ? "登录页常亮已开启" : "登录页常亮已关闭"
    }

    // MARK: 删除

    func confirmDelete(_ item: WPItem) {
        confirm(text: "删除「\(item.name)」？", info: "只删除软件壁纸库内副本，不影响原始图片。") {
            try? FileManager.default.removeItem(at: item.url)
            if self.desktopID == item.id { self.desktopID = self.items.first { $0.id != item.id }?.id }
            if self.lockID == item.id { self.lockID = self.items.first { $0.id != item.id }?.id }
            self.loadLibrary()
        }
    }

    private func confirm(text: String, info: String, action: @escaping () -> Void) {
        let a = NSAlert(); a.messageText = text; a.informativeText = info; a.alertStyle = .warning
        a.addButton(withTitle: "确定"); a.addButton(withTitle: "取消")
        NSApp.activate(ignoringOtherApps: true)
        if a.runModal() == .alertFirstButtonReturn { action() }
    }

    // MARK: 立即锁屏 / 密码

    func lockNow() { coord.lockNow() }

    func savePassword() {
        coord.setPassword(passwordField)
        hasPassword = Keychain.hasPassword
        passwordField = ""
        notice = hasPassword ? "已保存自动解锁密码（仅存本机钥匙串）" : "已清除自动解锁密码"
    }

    // MARK: 远程 / 邻近

    func toggleRemote(_ on: Bool) {
        HaloStore.shared.remoteEnabled = on; remoteEnabled = on
        if on { coord.server.start() } else { coord.server.stop() }
    }
    func resetPairCode() { pairCode = HaloStore.shared.regeneratePairCode(); notice = "已生成新配对码" }

    func setProx(_ mutate: (inout ProximityConfig) -> Void) {
        var c = prox; mutate(&c); coord.proximity.update(c); prox = c
    }
    func startPairing() { coord.proximity.startPairing(); notice = "正在搜索广播 Halo 的 iPhone…（30 秒）" }
    func pairDevice(_ d: ProximityLock.DiscoveredDevice) {
        coord.proximity.pair(with: d); prox = coord.proximity.config
        notice = "已绑定 \(d.name)"
    }
}
