//
//  AppModel.swift — iPhone 端全局状态
//

import Foundation
import Combine
import SwiftUI

@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()

    let client = HaloClient()
    // 惰性：只有进入「靠近」页访问 beacon 时才初始化蓝牙，App 启动与其它页面完全不碰 CoreBluetooth
    lazy var beacon = ProximityBeacon()

    @Published var ping: PingResponse?
    @Published var wallpapers: [WallpaperInfo] = []
    @Published var desktopID: String?
    @Published var lockID: String?
    @Published var busy = false
    @Published var toast: String?
    @Published var proximity = ProximityConfig()

    // 缩略图内存缓存 id -> UIImage
    private var thumbCache: [String: UIImage] = [:]
    private var poller: Timer?

    private init() {
        client.startBrowsing()
    }

    var connected: Bool { client.connected }
    var macName: String { ping?.name ?? client.targetName }

    // MARK: 连接

    func connect(target: HaloTarget, name: String) async {
        busy = true; defer { busy = false }
        do {
            let p = try await client.connect(target, name: name)
            self.ping = p
            try? await refresh()
            self.proximity = p.proximity
            startPolling()
            toast("已连接 \(p.name)")
        } catch {
            toast(error.localizedDescription)
        }
    }

    func disconnect() {
        client.disconnect()
        poller?.invalidate(); poller = nil
        ping = nil; wallpapers = []
    }

    // MARK: 刷新

    func refresh() async throws {
        let s = try await client.getStatus()
        self.ping = s.ping
        self.wallpapers = s.wallpapers
        self.desktopID = s.desktopID
        self.lockID = s.lockID
    }

    func startPolling() {
        poller?.invalidate()
        poller = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.client.connected else { return }
                if let p = try? await self.client.getPing() { self.ping = p }
            }
        }
    }

    // MARK: 操作

    func lockNow() async {
        do { try await client.lock(); toast("已让 Mac 锁屏") }
        catch { toast(error.localizedDescription) }
    }

    func assign(_ slot: SlotKind, id: String) async {
        do {
            try await client.setSlot(slot, id: id)
            if slot == .desktop { desktopID = id } else { lockID = id }
        } catch { toast(error.localizedDescription) }
    }

    func apply() async {
        busy = true; defer { busy = false }
        do {
            try await client.apply(desktop: desktopID, lock: lockID)
            toast("已应用到 Mac")
            try? await refresh()
        } catch { toast(error.localizedDescription) }
    }

    func uploadAndAssign(image: UIImage, assign: SlotKind?) async {
        busy = true; defer { busy = false }
        guard let data = image.jpegData(compressionQuality: 0.92) else { toast("图片读取失败"); return }
        let stamp = Int(Date().timeIntervalSince1970)
        do {
            let r = try await client.upload(name: "iPhone-\(stamp)", ext: "jpg", data: data, assign: assign)
            if r.ok {
                toast(assign == nil ? "已上传到 Mac 壁纸库" : "已上传并指派")
                try? await refresh()
            } else { toast(r.error ?? "上传失败") }
        } catch { toast(error.localizedDescription) }
    }

    func saveProximity(_ c: ProximityConfig) async {
        do { try await client.setProximity(c); self.proximity = c; toast("已同步靠近设置") }
        catch { toast(error.localizedDescription) }
    }

    // MARK: 缩略图

    func thumbnail(_ id: String) -> UIImage? {
        if let img = thumbCache[id] { return img }
        Task { @MainActor in
            if let d = try? await client.thumbData(id: id), let img = UIImage(data: d) {
                self.thumbCache[id] = img
                self.objectWillChange.send()
            }
        }
        return nil
    }

    func toast(_ s: String) {
        withAnimation { toast = s }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.2) { [weak self] in
            if self?.toast == s { withAnimation { self?.toast = nil } }
        }
    }
}
