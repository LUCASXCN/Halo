//
//  DesktopOverlay.swift — 用户态常驻「桌面覆盖进程」
//  ─────────────────────────────────────────────────────────────
//  反转法的一半：系统真正的壁纸由主 App 用公开 API 设成「登录页图」
//  （锁屏 / 开机登录页因此自动等于它）；本进程在桌面壁纸层之上、桌面
//  图标之下渲染用户真正想在桌面看到的「桌面显示图」，从而让两者不同。
//
//  特性：
//   · 每块屏幕一个 borderless 覆盖窗，位于 kCGDesktopWindowLevel
//   · ignoresMouseEvents 完全点击穿透（桌面图标可正常单击/双击/框选/右键）
//   · canJoinAllSpaces + stationary：跨所有桌面空间、Mission Control、全屏
//   · CALayer.resizeAspectFill：充满屏幕·居中裁剪，静态图零 CPU
//   · DispatchSource 监听配置文件，热切换图片 / 开关，无需重启
//   · 监听屏幕参数变化，自动增删/重排覆盖窗
//   · 「登录页常亮」：用户会话内 IOKit 电源断言，锁屏且开启时阻止显示睡眠
//   · accessory 策略，不进 Dock、不抢焦点
//
//  配置：~/Library/Application Support/Halo/config.plist
//       active(Bool) desktopImagePath(String) keepAwake(Bool)
//  用法：DesktopOverlay run   （由用户态 LaunchAgent 常驻拉起）
//

import AppKit
import IOKit.pwr_mgt
import Darwin
import Dispatch

// MARK: - 配置

struct OverlayConfig {
    var active = false
    var desktopImagePath = ""
    var keepAwake = false
}

final class ConfigStore {
    let url: URL
    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask)[0]
            .appendingPathComponent("Halo", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        url = base.appendingPathComponent("config.plist")
    }
    func read() -> OverlayConfig {
        guard let d = NSDictionary(contentsOf: url) else { return OverlayConfig() }
        var c = OverlayConfig()
        c.active = (d["active"] as? Bool) ?? false
        c.desktopImagePath = (d["desktopImagePath"] as? String) ?? ""
        c.keepAwake = (d["keepAwake"] as? Bool) ?? false
        return c
    }
}

// MARK: - 充满屏图像视图（CALayer aspect-fill，静态、零 CPU）

final class FillView: NSView {
    private let imageLayer = CALayer()
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer = CALayer()
        layer?.addSublayer(imageLayer)
        imageLayer.contentsGravity = .resizeAspectFill   // 充满·居中裁剪
        imageLayer.masksToBounds = true
        imageLayer.frame = bounds
    }
    required init?(coder: NSCoder) { fatalError() }
    override func layout() {
        super.layout()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        imageLayer.frame = bounds
        CATransaction.commit()
    }
    func setImage(path: String) {
        guard FileManager.default.fileExists(atPath: path),
              let ns = NSImage(contentsOfFile: path) else { imageLayer.contents = nil; return }
        var rect = CGRect(origin: .zero, size: ns.size)
        let cg = ns.cgImage(forProposedRect: &rect, context: nil, hints: nil)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        imageLayer.contents = cg
        CATransaction.commit()
    }
    func clear() { CATransaction.begin(); CATransaction.setDisableActions(true); imageLayer.contents = nil; CATransaction.commit() }
}

// MARK: - 单屏覆盖窗

final class CoverWindow {
    let screen: NSScreen
    private var win: NSWindow!
    private var fill: FillView!

    init(screen: NSScreen) {
        self.screen = screen
        let f = screen.frame
        win = NSWindow(contentRect: f, styleMask: [.borderless], backing: .buffered, defer: false, screen: screen)
        win.isOpaque = true
        win.backgroundColor = .clear
        win.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)))
        win.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        win.ignoresMouseEvents = true       // 点击穿透
        win.hasShadow = false
        win.isMovable = false
        win.isReleasedWhenClosed = false
        win.animationBehavior = .none
        fill = FillView(frame: NSRect(origin: .zero, size: f.size))
        win.contentView = fill
        win.orderFront(nil)
    }
    func setImage(_ path: String) { fill.setImage(path: path) }
    func clear() { fill.clear() }
    func close() { win.orderOut(nil) }
    func matches(_ s: NSScreen) -> Bool { s == screen }
}

// MARK: - 控制器

final class OverlayController: NSObject {
    private let store = ConfigStore()
    private var covers: [CoverWindow] = []
    private var cfg = OverlayConfig()
    private var fileSrc: DispatchSourceFileSystemObject?
    private var fileFD: Int32 = -1

    // 常亮
    private var assertionID: IOPMAssertionID = IOPMAssertionID(0)
    private var assertionHeld = false
    private var locked = false

    func run() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)   // 不进 Dock、不抢焦点
        let delegate = AppDel(controller: self)
        app.delegate = delegate
        rebuild()
        watchConfig()
        watchScreens()
        watchLockState()
        app.run()
    }

    // MARK: 覆盖窗

    private func rebuild() {
        cfg = store.read()
        // 屏幕增删
        let current = NSScreen.screens
        // 移除已不存在的
        covers.filter { cw in !current.contains(where: { $0 == cw.screen }) }.forEach { $0.close() }
        covers.removeAll { cw in !current.contains(where: { $0 == cw.screen }) }
        // 为新屏幕创建
        for s in current where !covers.contains(where: { $0.matches(s) }) {
            covers.append(CoverWindow(screen: s))
        }
        applyImage()
        applyAssertion()
    }

    private func applyImage() {
        if cfg.active && !cfg.desktopImagePath.isEmpty {
            for c in covers { c.setImage(cfg.desktopImagePath) }
        } else {
            for c in covers { c.clear() }
        }
    }

    private func watchScreens() {
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { self?.rebuild() }
        }
    }

    // MARK: 配置热切换（对配置文件只读，绝不创建/写入，避免与主程序写入竞争）

    private var retryTimer: DispatchSourceTimer?

    private func watchConfig() {
        retryTimer?.cancel(); retryTimer = nil
        fileSrc?.cancel(); fileSrc = nil
        let path = store.url.path
        fileFD = open(path, O_EVTONLY)
        guard fileFD >= 0 else {
            // 配置尚未出现：0.5s 后重试，期间不创建任何文件
            let t = DispatchSource.makeTimerSource(queue: .main)
            t.schedule(deadline: .now() + 0.5)
            t.setEventHandler { [weak self] in self?.watchConfig() }
            retryTimer = t; t.resume()
            return
        }
        let src = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fileFD,
                                                            eventMask: [.write, .rename, .delete, .extend],
                                                            queue: .main)
        src.setEventHandler { [weak self] in
            guard let self else { return }
            self.fileSrc?.cancel()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                let old = self.cfg
                self.cfg = self.store.read()
                if old.desktopImagePath != self.cfg.desktopImagePath || old.active != self.cfg.active {
                    self.applyImage()
                }
                if old.keepAwake != self.cfg.keepAwake { self.applyAssertion() }
                self.watchConfig()
            }
        }
        src.setCancelHandler { [weak self] in if let self, self.fileFD >= 0 { close(self.fileFD); self.fileFD = -1 } }
        fileSrc = src
        src.resume()
    }

    // MARK: 常亮（用户态电源断言）

    private func watchLockState() {
        let dnc = DistributedNotificationCenter.default()
        dnc.addObserver(forName: NSNotification.Name("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in
            self?.locked = true; self?.applyAssertion()
        }
        dnc.addObserver(forName: NSNotification.Name("com.apple.screenIsUnlocked"), object: nil, queue: .main) { [weak self] _ in
            self?.locked = false; self?.applyAssertion()
        }
    }

    private func applyAssertion() {
        let want = cfg.keepAwake && locked
        if want && !assertionHeld {
            let reason = "Halo keep login screen awake" as CFString
            let r = IOPMAssertionCreateWithName(kIOPMAssertPreventUserIdleDisplaySleep as CFString,
                                                IOPMAssertionLevel(kIOPMAssertionLevelOn), reason, &assertionID)
            if r == kIOReturnSuccess { assertionHeld = true; NSLog("[HaloOverlay] 常亮断言已持有") }
        } else if !want && assertionHeld {
            IOPMAssertionRelease(assertionID); assertionHeld = false; NSLog("[HaloOverlay] 常亮断言已释放")
        }
    }
}

private final class AppDel: NSObject, NSApplicationDelegate {
    let controller: OverlayController
    init(controller: OverlayController) { self.controller = controller }
    func applicationDidFinishLaunching(_ n: Notification) {}
}

// MARK: - 入口

let mode = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "run"
switch mode {
case "run":
    OverlayController().run()
default:
    OverlayController().run()
}
