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
import IOKit
import IOKit.pwr_mgt
import os.log

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
    private let log = OSLog(subsystem: "com.lucas.halo", category: "ScreenLocker")

    // 锁屏状态变化回调（主线程）
    var onLockStateChange: ((Bool) -> Void)?

    private var pollTimer: DispatchSourceTimer?
    private var lastLocked = false
    // 分布式通知记录的状态，作为 notify 读取失败时的兜底
    private var notifiedLocked = false
    // 解锁重入锁：防止 /unlock API 和蓝牙靠近检测同时触发多个解锁流程
    private var isUnlocking = false
    private let unlockLock = NSLock()

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

    /// 屏幕保护方式锁屏（关键：屏保退出后的登录窗允许 CGEvent 投递密码，
    /// 而 SACLockScreenImmediate 直接进入安全会话会拦截所有第三方 CGEvent）
    private func screensaverLock() -> Bool {
        let screensaverURL = URL(fileURLWithPath: "/System/Library/CoreServices/ScreenSaverEngine.app")
        NSWorkspace.shared.open(screensaverURL)
        return true
    }

    /// 静态链接的私有即时锁屏（备选：当屏保方式不可用时）
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
            // 和 BLEUnlock 一致：默认用 SACLockScreenImmediate 直接进登录页
            // （entitlements com.apple.security.automation.apple-events 允许 CGEvent 投递到 loginwindow）
            if !self.privateLock() { self.cgeventLock() }
        }
    }

    // MARK: 唤醒显示器（靠近解锁时先唤醒，避免黑屏态密码框不显示）

    /// 唤醒显示器（仅 IOPMAssertion 保持唤醒，不移动鼠标——对齐 BLEUnlock）
    func wakeDisplay() {
        // 持有 15 秒唤醒断言，防止输入密码期间显示器休眠
        var assertion: IOPMAssertionID = 0
        IOPMAssertionCreateWithName(
            "PreventUserIdleDisplaySleep" as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            "Halo 靠近解锁期间保持显示器唤醒" as CFString,
            &assertion
        )
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 15) {
            IOPMAssertionRelease(assertion)
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

    /// 用 Keychain 中保存的密码自动解锁（BLEUnlock 原理：CGEventKeyboardSetUnicodeString + 多次重试）。
    /// 注意：调用方必须在后台线程调用，本方法会阻塞当前线程。
    /// BLEUnlock 最多重试 8 次，因为唤醒时第一次尝试可能在登录 UI 就绪前执行。
    func autoUnlockFromKeychain(retry: Bool = true, completion: ((Bool) -> Void)? = nil) {
        // 重入锁：防止多个解锁流程同时执行（互相干扰 Escape/回车/密码投递）
        unlockLock.lock()
        if isUnlocking {
            unlockLock.unlock()
            debugLog("🔑 autoUnlockFromKeychain 跳过：已有解锁流程在执行")
            completion?(false)
            return
        }
        isUnlocking = true
        unlockLock.unlock()
        defer {
            unlockLock.lock()
            isUnlocking = false
            unlockLock.unlock()
        }

        debugLog("🔑 autoUnlockFromKeychain 开始 isLocked=\(isLocked)")
        guard isLocked, let password = Keychain.read(), !password.isEmpty else {
            debugLog("🔑 autoUnlockFromKeychain 中止：isLocked=\(isLocked) hasPassword=\(Keychain.read() != nil)")
            completion?(false); return
        }
        debugLog("🔑 密码已读取(长度\(password.count))")

        // 对齐 BLEUnlock：直接投递密码（entitlements 允许 CGEvent 投递到 loginwindow）
        // 不需要前置回车或鼠标操作——loginwindow 收到第一个密码字符后会自动显示密码框

        // 最多重试 5 次（BLEUnlock 用 8 次），每次间隔 1.5 秒
        // 唤醒时第一次尝试可能在登录 UI 完全就绪前执行，需要多次重试
        let maxAttempts = 5
        for attempt in 1...maxAttempts {
            if !isLocked {
                debugLog("🔑 第\(attempt)次尝试前已解锁，成功")
                completion?(true)
                return
            }
            debugLog("🔑 第\(attempt)/\(maxAttempts)次尝试投递密码")
            // 等密码框就绪（第一次等 0.5 秒，后续等 1.5 秒）
            usleep(attempt == 1 ? 500_000 : 1_500_000)
            typePasswordViaUnicodeString(password)
            usleep(1_500_000) // 等系统处理密码+回车+notify状态更新（确保下次循环能检测到已解锁）
        }

        let ok = !isLocked
        debugLog("🔑 autoUnlockFromKeychain 最终结果：\(ok ? "成功" : "失败")（\(maxAttempts)次尝试后）")
        completion?(ok)
    }

    /// BLEUnlock 核心方式：CGEventKeyboardSetUnicodeString 一次性投递整个密码字符串，然后回车
    /// 关键：所有 CGEvent 必须在主线程投递（锁屏时后台线程投递的事件可能被系统忽略）
    private func typePasswordViaUnicodeString(_ password: String) {
        debugLog("⌨️ typePasswordViaUnicodeString 开始投递密码 (主线程投递)")

        DispatchQueue.main.sync {
            let src = CGEventSource(stateID: .hidSystemState)

            // 1. 用 CGEventKeyboardSetUnicodeString 投递密码（virtualKey=49 空格键，每20字符一批）
            let PER = 20
            let uniCharCount = password.utf16.count
            var strIndex = password.utf16.startIndex
            for offset in stride(from: 0, to: uniCharCount, by: PER) {
                let len = offset + PER < uniCharCount ? PER : uniCharCount - offset
                let buffer = UnsafeMutablePointer<UniChar>.allocate(capacity: len)
                for i in 0..<len {
                    buffer[i] = password.utf16[strIndex]
                    strIndex = password.utf16.index(after: strIndex)
                }
                if let pressEvent = CGEvent(keyboardEventSource: src, virtualKey: 49, keyDown: true) {
                    pressEvent.keyboardSetUnicodeString(stringLength: len, unicodeString: buffer)
                    pressEvent.post(tap: .cghidEventTap)
                }
                usleep(15_000)
                CGEvent(keyboardEventSource: src, virtualKey: 49, keyDown: false)?.post(tap: .cghidEventTap)
                buffer.deallocate()
                usleep(50_000)
            }
            debugLog("⌨️ 密码已投递 (\(uniCharCount)字符)")
            usleep(200_000)

            // 2. Return 确认（标准 Return vk=36）
            CGEvent(keyboardEventSource: src, virtualKey: 36, keyDown: true)?.post(tap: .cghidEventTap)
            usleep(15_000)
            CGEvent(keyboardEventSource: src, virtualKey: 36, keyDown: false)?.post(tap: .cghidEventTap)
            debugLog("⌨️ Return 已投递 (vk=36)")
        }
    }

    /// 文件日志（os_log 在 ad-hoc 签名下可能不输出，用文件更可靠）
    private func debugLog(_ msg: String) {
        let line = "\(Date().formatted(.dateTime.hour().minute().second())) \(msg)\n"
        if let data = line.data(using: .utf8) {
            let path = "/tmp/halo_unlock_debug.log"
            if let handle = FileHandle(forWritingAtPath: path) {
                handle.seekToEndOfFile()
                handle.write(data)
                try? handle.close()
            } else {
                try? data.write(to: URL(fileURLWithPath: path))
            }
        }
    }
}
