//
//  ScreenLocker.swift — 锁屏 / 自动输入密码解锁 / 锁屏状态监听（融合 BLEUnlock 原理）
//  ─────────────────────────────────────────────────────────────────────────────
//  · 锁屏：静态链接 login.framework 私有 SACLockScreenImmediate（与 BLEUnlock 同路径，
//    已在 macOS 26/27 验证：调用后约 0.4s 进入锁定态）；极端情况下回退合成 ⌃⌘Q。
//  · 锁屏状态判据：macOS 27 起 CGSessionCopyCurrentDictionary 不再返回
//    kCGSSessionScreenIsLocked（恒读不到），改用系统权威的 Darwin notify 共享状态
//    "com.apple.sessionagent.screenIsLocked"（loginwindow 锁屏时置 1、解锁置 0），
//    分布式通知做即时响应、1s 轮询做兜底。
//  · 解锁：CGEvent.keyboardSetUnicodeString 逐字符精确输入（与 BLEUnlock 一致，
//    投递 .cghidEventTap 到达 loginwindow），最后回车。密码只从 Keychain 取。
//

import AppKit
import CoreGraphics
import Foundation

// MARK: - 私有锁屏符号（编译期两级命名空间静态链接，见 vendor/login.tbd）
@_silgen_name("SACLockScreenImmediate")
private func haloSACLockScreenImmediate()

// MARK: - Darwin notify 锁屏状态（系统权威共享状态，跨 macOS 26/27 可靠）
@_silgen_name("notify_register_check")
private func haloNotifyRegisterCheck(_ name: UnsafePointer<CChar>, _ token: UnsafeMutablePointer<Int32>) -> Int32
@_silgen_name("notify_get_state")
private func haloNotifyGetState(_ token: Int32, _ state: UnsafeMutablePointer<UInt64>) -> Int32

/// 锁屏状态读取器：进程内只注册一次 notify token，之后只读共享内存（无分配、无权限弹窗）
private final class LockStateReader {
    static let shared = LockStateReader()
    private let tokenName = "com.apple.sessionagent.screenIsLocked"
    private var token: Int32 = -1
    private let lock = NSLock()

    /// 1=已锁屏，0=未锁屏，-1=读取失败
    func rawValue() -> Int {
        lock.lock(); defer { lock.unlock() }
        if token < 0 {
            let t = haloNotifyRegisterCheck(tokenName, &token)
            if t != 0 { token = -1; return -1 }
        }
        var s: UInt64 = 0
        guard haloNotifyGetState(token, &s) == 0 else { return -1 }
        return s == 0 ? 0 : 1
    }
}

final class ScreenLocker {
    static let shared = ScreenLocker()

    // 锁屏状态变化回调（主线程）
    var onLockStateChange: ((Bool) -> Void)?

    private var pollTimer: DispatchSourceTimer?
    private var lastLocked = false
    // 分布式通知记录的状态，作为 notify 读取失败时的兜底
    private var notifiedLocked = false

    private init() {}

    // MARK: 状态

    /// 当前是否处于会话锁屏/登录窗（macOS 27 权威判据）
    var isLocked: Bool {
        switch LockStateReader.shared.rawValue() {
        case 1: return true
        case 0: return false
        default: return notifiedLocked   // notify 暂不可用时退回通知记录
        }
    }

    func startObserving() {
        lastLocked = isLocked
        let dnc = DistributedNotificationCenter.default()
        dnc.addObserver(forName: NSNotification.Name("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in
            self?.notifiedLocked = true; self?.emit(true)
        }
        dnc.addObserver(forName: NSNotification.Name("com.apple.screenIsUnlocked"), object: nil, queue: .main) { [weak self] _ in
            self?.notifiedLocked = false; self?.emit(false)
        }
        // 1s 轮询兜底，防止私有通知偶发丢失（使用权威 notify 判据）
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now() + 1, repeating: 1)
        t.setEventHandler { [weak self] in
            guard let self else { return }
            let now = self.isLocked
            self.notifiedLocked = now
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

    /// 静态链接的私有即时锁屏（与 BLEUnlock 完全相同的调用路径）
    private func privateLock() -> Bool {
        haloSACLockScreenImmediate()
        return true
    }

    /// 公开 API 兜底：模拟 ⌃⌘Q 锁屏快捷键（仅当私有路径异常时）
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
