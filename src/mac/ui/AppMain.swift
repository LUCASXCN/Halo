//
//  AppMain.swift — 菜单栏常驻 App + 液态玻璃主窗口
//  ─────────────────────────────────────────────────────────────────
//  · 全程 .accessory：Dock 永不显示图标，只在菜单栏常驻（符合「关窗后菜单栏运行」）
//  · 关闭主窗口只是隐藏；点菜单栏图标 / 菜单「显示 Halo」重新打开
//  · 非控件区可拖动窗口，拖动期间冻结玻璃逐帧折射以跟手
//

import SwiftUI
import AppKit
import Combine

/// 全局窗口拖拽状态
final class DragMonitor: ObservableObject {
    static let shared = DragMonitor()
    @Published var isDragging = false
    private var settle: DispatchWorkItem?
    private init() {}
    func dragBegan() { settle?.cancel(); if !isDragging { isDragging = true }; arm() }
    func dragMoved() { arm() }
    private func arm() {
        settle?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.isDragging = false }
        settle = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: w)
    }
}

final class DragHostingView<Content: View>: NSHostingView<Content> {
    override var mouseDownCanMoveWindow: Bool { true }
}

// MARK: - 窗口与菜单栏控制器（单例，供 SwiftUI 调用）

final class AppShell: NSObject, NSWindowDelegate {
    static let shared = AppShell()
    fileprivate var window: NSWindow?
    fileprivate var statusItem: NSStatusItem?
    private let winW: CGFloat = 1120
    private let winH: CGFloat = 760

    lazy var menu = StatusMenu(controller: self)

    func buildStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(systemSymbolName: "dot.radiowaves.left.and.right",
                                     accessibilityDescription: "Halo")
        item.button?.image?.isTemplate = true
        item.menu = menu.make()
        statusItem = item
    }

    func showWindow() {
        if window == nil { makeWindow() }
        guard let window else { return }
        enforceFrame()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func hideWindow() { window?.orderOut(nil) }

    /// 红叉 / ⌘W：拦截真正关闭，改为隐藏到菜单栏（进程与菜单栏常驻）
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        sender.orderOut(nil)
        return false
    }

    // MARK: 菜单栏动作（显式 target，避免响应链找不到而变灰）
    @objc func showWin() { showWindow() }
    @objc func menuLockNow() { AppCoordinator.shared.lockNow() }
    @objc func quitHalo() { NSApp.terminate(nil) }

    private func enforceFrame() {
        guard let window else { return }
        let f = window.frame
        guard abs(f.width - winW) > 1 || abs(f.height - winH) > 1 else { return }
        guard let screen = window.screen ?? NSScreen.main else { return }
        let v = screen.visibleFrame
        let o = NSPoint(x: v.midX - winW / 2, y: v.midY - winH / 2)
        window.setFrame(NSRect(origin: o, size: NSSize(width: winW, height: winH)), display: true, animate: false)
    }

    private func makeWindow() {
        let hosting = DragHostingView(rootView: ContentView())
        hosting.translatesAutoresizingMaskIntoConstraints = true
        hosting.autoresizingMask = [.width, .height]
        hosting.frame = NSRect(x: 0, y: 0, width: winW, height: winH)
        hosting.sizingOptions = []

        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: winW, height: winH),
                         styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
                         backing: .buffered, defer: false)
        w.isOpaque = false
        w.backgroundColor = .clear
        w.hasShadow = true
        w.titlebarAppearsTransparent = true
        w.titleVisibility = .hidden
        w.isMovableByWindowBackground = true
        w.animationBehavior = .none
        w.isRestorable = false
        w.minSize = NSSize(width: winW, height: winH)
        w.maxSize = NSSize(width: winW, height: winH)
        w.contentView = hosting
        w.setContentSize(NSSize(width: winW, height: winH))
        w.center()
        w.isReleasedWhenClosed = false
        w.delegate = self
        window = w

        let nc = NotificationCenter.default
        nc.addObserver(forName: NSWindow.willMoveNotification, object: w, queue: .main) { _ in DragMonitor.shared.dragBegan() }
        nc.addObserver(forName: NSWindow.didMoveNotification, object: w, queue: .main) { _ in DragMonitor.shared.dragMoved() }
        DragMonitor.shared.$isDragging.sink { [weak self] d in self?.window?.hasShadow = !d }.store(in: &observers)
    }

    private var observers = Set<AnyCancellable>()
}

// MARK: - 菜单栏菜单

final class StatusMenu {
    weak var controller: AppShell?
    private var rawMenu: NSMenu?
    init(controller: AppShell) {
        self.controller = controller
        NotificationCenter.default.addObserver(forName: NSMenu.didBeginTrackingNotification,
                                               object: nil, queue: .main) { [weak self] _ in self?.refreshState() }
    }

    func make() -> NSMenu {
        let m = NSMenu()
        m.addItem(item("显示 Halo", #selector(AppShell.showWin), key: "0"))
        m.addItem(item("立即锁屏", #selector(AppShell.menuLockNow), key: "L"))
        m.addItem(.separator())
        let state = NSMenuItem(title: "设备状态", action: nil, keyEquivalent: ""); state.isEnabled = false; m.addItem(state)
        m.addItem(.separator())
        m.addItem(item("退出 Halo", #selector(AppShell.quitHalo), key: "q"))
        rawMenu = m
        refreshState()
        return m
    }

    private func refreshState() {
        guard let m = rawMenu else { return }
        let c = AppCoordinator.shared
        let ble = c.proximity.state
        let line: String
        if ble.connected { line = "已连接 \(ble.deviceName) · \(ble.rssi)dBm · \(zoneText(ble.zone))" }
        else if c.server.running { line = "局域网待命 · 端口 \(c.server.boundPort)" }
        else { line = "菜单栏运行中" }
        for it in m.items where it.action == nil && !it.isSeparatorItem { it.title = line }
    }
    private func zoneText(_ z: String) -> String {
        ["near": "在附近", "far": "已远离", "searching": "搜索中"][z] ?? z
    }
    private func item(_ t: String, _ sel: Selector, key: String) -> NSMenuItem {
        let it = NSMenuItem(title: t, action: sel, keyEquivalent: key)
        it.target = AppShell.shared
        return it
    }
}

// MARK: - App 入口

@main
struct MainEntry {
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)   // 纯菜单栏 App，不进 Dock
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var launchGuard: Timer?
    private var launchTicks = 0

    func applicationDidFinishLaunching(_ n: Notification) {
        UserDefaults.standard.set(false, forKey: "NSQuitAlwaysKeepsWindows")
        UserDefaults.standard.set(false, forKey: "ApplePersistenceIgnoreState")
        installMainMenu()   // accessory 也补最小菜单，让 ⌘W 能关窗（被拦截为隐藏）
        AppCoordinator.shared.boot()
        AppShell.shared.buildStatusItem()
        AppShell.shared.showWindow()   // 首次启动展示一次主界面
        // 启动初期确保窗口前置
        launchGuard = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] t in
            guard let self else { t.invalidate(); return }
            if NSApp.isActive == false { NSApp.activate(ignoringOtherApps: true) }
            self.launchTicks += 1
            if self.launchTicks >= 20 { t.invalidate() }
        }
    }

    // 纯菜单栏 App：最后一个窗口关闭也不退出（窗口只是隐藏）
    func applicationShouldTerminateAfterLastWindowClosed(_ s: NSApplication) -> Bool { false }

    /// accessory 进程默认无主菜单，补一个最小菜单：⌘W 关闭窗口、⌘Q 退出
    private func installMainMenu() {
        let root = NSMenu()
        // App 菜单（提供 ⌘Q）
        let appItem = NSMenuItem(); root.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "退出 Halo", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        // 文件菜单（提供 ⌘W → performClose → windowShouldClose 拦截为隐藏）
        let fileItem = NSMenuItem(); root.addItem(fileItem)
        let fileMenu = NSMenu()
        let close = NSMenuItem(title: "关闭", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        fileMenu.addItem(close)
        fileItem.submenu = fileMenu
        NSApp.mainMenu = root
    }
}
