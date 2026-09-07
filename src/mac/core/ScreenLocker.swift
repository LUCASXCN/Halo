//
//  ScreenLocker.swift — 锁屏 / 自动输入密码解锁 / 锁屏状态监听（融合 BLEUnlock 原理）
//  ─────────────────────────────────────────────────────────────────────────────
//  · 锁屏：优先 macOS 私有 SACLockScreenImmediate（运行时解析，缺失则回退公开
//    CGEvent 发送 ⌃⌘Q），跨 macOS 26/27 可用。
//  · 解锁：CGEvent.keyboardSetUnicodeString 逐字符精确输入（不受键盘布局影响），
//    投递到 .cghidEventTap 以到达 loginwindow，最后回车。密码只从 Keychain 取。
//

import AppKit
import CoreGraphics
import Foundation

final class ScreenLocker {
    static let shared = ScreenLocker()

    // 锁屏状态变化回调（主线程）
    var onLockStateChange: ((Bool) -> Void)?

    private var pollTimer: DispatchSourceTimer?
    private var lastLocked = false

    private init() {}

    // MARK: 状态

    /// 当前是否处于会话锁屏/登录窗
    var isLocked: Bool {
        guard let d = CGSessionCopyCurrentDictionary() as? [String: Any],
              let v = d["kCGSSessionScreenIsLocked"] as? Int else { return false }
        return v != 0
    }

    func startObserving() {
        lastLocked = isLocked
        let dnc = DistributedNotificationCenter.default()
        dnc.addObserver(forName: NSNotification.Name("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in
            self?.emit(true)
        }
        dnc.addObserver(forName: NSNotification.Name("com.apple.screenIsUnlocked"), object: nil, queue: .main) { [weak self] _ in
            self?.emit(false)
        }
        // 1s 轮询兜底，防止私有通知偶发丢失
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now() + 1, repeating: 1)
        t.setEventHandler { [weak self] in
            guard let self else { return }
            let now = self.isLocked
            if now != self.lastLocked { self.emit(now) }
        }
        pollTimer = t; t.resume()
    }

    private func emit(_ locked: Bool) {
        guard locked != lastLocked else { return }
        lastLocked = locked
        DispatchQueue.main.async { self.onLockStateChange?(locked) }
    }

    // MARK: 锁屏

    /// 私有即时锁屏函数签名：void(void)
    private typealias ImmediateLockFn = @convention(c) () -> Void

    private func privateLock() -> Bool {
        guard let handle = dlopen("/System/Library/PrivateFrameworks/login.framework/login", RTLD_LAZY) else { return false }
        guard let sym = dlsym(handle, "SACLockScreenImmediate") else { return false }
        let fn = unsafeBitCast(sym, to: ImmediateLockFn.self)
        fn()
        return true
    }

    /// 公开 API 兜底：模拟 ⌃⌘Q 锁屏快捷键
    private func cgeventLock() {
        let src = CGEventSource(stateID: .hidSystemState)
        let vkQ: CGKeyCode = 12
        let flags: CGEventFlags = [.maskCommand, .maskControl]
        let down = CGEvent(keyboardEventSource: src, virtualKey: vkQ, keyDown: true)
        down?.flags = flags
        let up = CGEvent(keyboardEventSource: src, virtualKey: vkQ, keyDown: false)
        up?.flags = flags
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }

    func lockNow() {
        DispatchQueue.main.async {
            if !self.privateLock() { self.cgeventLock() }
        }
    }

    // MARK: 自动输入密码解锁

    /// 逐字符输入任意字符串（Unicode 精确输入，到 HID 层，loginwindow 可接收）
    private func typeString(_ text: String, tap: CGEventTapLocation = .cghidEventTap, perKeyDelay: UInt32 = 28_000) {
        let src = CGEventSource(stateID: .hidSystemState)
        let scalars = Array(text.utf16)
        for ch in scalars {
            var u = ch
            let down = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: true)
            down?.keyboardSetUnicodeString(stringLength: 1, unicodeString: &u)
            let up = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: false)
            up?.keyboardSetUnicodeString(stringLength: 1, unicodeString: &u)
            down?.post(tap: tap)
            up?.post(tap: tap)
            usleep(perKeyDelay)
        }
    }

    private func tapKey(_ vk: CGKeyCode, tap: CGEventTapLocation = .cghidEventTap) {
        let src = CGEventSource(stateID: .hidSystemState)
        CGEvent(keyboardEventSource: src, virtualKey: vk, keyDown: true)?.post(tap: tap)
        usleep(12_000)
        CGEvent(keyboardEventSource: src, virtualKey: vk, keyDown: false)?.post(tap: tap)
    }

    /// 用 Keychain 中保存的密码自动解锁。返回是否最终进入解锁态。
    func autoUnlockFromKeychain(retry: Bool = true, completion: ((Bool) -> Void)? = nil) {
        guard isLocked, let password = Keychain.read(), !password.isEmpty else {
            completion?(false); return
        }
        DispatchQueue.global(qos: .userInitiated).async {
            // 等登录窗密码框就绪
            usleep(420_000)
            self.performTyping(password)
            // 校验是否解锁；未解锁则补一次（首帧密码框可能尚未聚焦）
            usleep(700_000)
            if self.isLocked && retry {
                usleep(400_000)
                self.performTyping(password)
                usleep(700_000)
            }
            let ok = !self.isLocked
            DispatchQueue.main.async { completion?(ok) }
        }
    }

    private func performTyping(_ password: String) {
        // 先取消可能遮挡的通知/控制中心焦点
        tapKey(53) // kVK_Escape
        usleep(120_000)
        typeString(password)
        usleep(160_000)
        tapKey(36) // kVK_Return
    }
}
