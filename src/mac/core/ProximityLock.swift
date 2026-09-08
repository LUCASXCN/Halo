//
//  ProximityLock.swift — 蓝牙靠近解锁（融合 BLEUnlock 原理，V1.4 重写）
//  ─────────────────────────────────────────────────────────────────────────────
//  架构对齐 BLEUnlock：
//    · Mac 扫描所有 BLE 设备 → 用户选定目标 iPhone → 自动连接 → 周期 readRSSI
//    · 双向阈值（awayRSSI 锁屏 / nearRSSI 解锁）+ 可配置 lockDelay（延迟锁定）
//    · didConnect 直接触发解锁（不等 RSSI 判定）+ 先唤醒显示器再输入密码
//    · 断开后宽限期 = lockDelay，期间尝试重连，仍失败则锁屏 + 发通知
//    · 手动解锁状态机：设备在远处时用户手动解锁 → 暂停自动锁；设备回近 → 恢复
//    · 搜索页防抖：候选设备每 1.5 秒批量刷新一次，避免列表跳动点不到
//
//  关键：iPhone 端不需要装任何蓝牙代码，Mac 直接连 iPhone 的系统蓝牙。
//

import Foundation
import CoreBluetooth
import Combine
import AppKit
import UserNotifications

final class ProximityLock: NSObject, ObservableObject {
    static let shared = ProximityLock()

    @Published var state = BLEStateInfo()
    @Published var config = ProximityConfig()
    /// 配对扫描期间发现的候选设备（供 UI 列表选择，已防抖批量更新）
    @Published var pairCandidates: [DiscoveredDevice] = []

    struct DiscoveredDevice: Identifiable, Hashable {
        let id: String        // peripheral.identifier.uuidString
        let name: String
        let rssi: Int
    }

    private var central: CBCentralManager!
    private var target: CBPeripheral?
    private let queue = DispatchQueue(label: "com.lucas.halo.ble", qos: .userInitiated)

    /// 纯逻辑判定引擎，仅在 queue 上访问
    private lazy var engine = ZoneDecisionEngine(awayRSSI: config.awayRSSI,
                                                 nearRSSI: config.nearRSSI,
                                                 dwellSeconds: config.dwellSeconds)
    private var rssiTimer: DispatchSourceTimer?
    private var pairingMode = false

    // MARK: 延迟锁定 / 状态机
    /// 远离后延迟锁定的 timer（queue 上）
    private var pendingLockTimer: DispatchSourceTimer?
    /// 断开后宽限期 timer（queue 上）
    private var disconnectGraceTimer: DispatchSourceTimer?
    /// 设备在远处时用户手动解锁 → 暂停自动锁，直到设备回近
    private var userUnlockedWhileAway = false
    /// 候选设备收集缓冲（防抖用）
    private var candidateBuffer: [String: DiscoveredDevice] = [:]
    private var candidateFlushTimer: DispatchSourceTimer?

    private override init() {
        super.init()
        config = HaloStore.shared.loadProximity()
        // 监听屏幕解锁事件：设备在远处时用户手动解锁 → 暂停自动锁
        ScreenLocker.shared.onLockStateChange = { [weak self] locked in
            guard let self else { return }
            if !locked {
                // 屏幕解锁了
                if self.state.zone == "far" || !self.state.connected {
                    // 设备在远处/未连接，说明是用户手动解锁
                    self.userUnlockedWhileAway = true
                    self.cancelPendingLock()
                }
            }
        }
        // 延迟到 runloop 之后再建中央端
        queue.async { [weak self] in
            guard let self else { return }
            self.central = CBCentralManager(delegate: self, queue: self.queue)
        }
    }

    // MARK: 对外控制

    func reloadConfig() {
        let c = HaloStore.shared.loadProximity()
        DispatchQueue.main.async { self.config = c; self.applyRunningState() }
    }

    func update(_ newConfig: ProximityConfig) {
        HaloStore.shared.saveProximity(newConfig)
        DispatchQueue.main.async {
            self.config = newConfig
            self.queue.async {
                self.engine.awayRSSI = newConfig.awayRSSI
                self.engine.nearRSSI = newConfig.nearRSSI
                self.engine.dwellSeconds = newConfig.dwellSeconds
                self.engine.reset()
                self.applyRunningState()
            }
        }
    }

    /// UI：进入配对扫描，30s 内收集附近所有 BLE 设备（防抖批量刷新）
    func startPairing() {
        queue.async {
            self.pairingMode = true
            self.candidateBuffer.removeAll()
            DispatchQueue.main.async { self.pairCandidates = [] }
            self.ensureScanning()
            self.startCandidateFlush()
            // 30 秒后自动退出配对扫描
            DispatchQueue.main.asyncAfter(deadline: .now() + 30) {
                self.pairingMode = false
                self.stopCandidateFlush()
            }
        }
    }

    /// UI：选定某台设备作为绑定目标
    func pair(with d: DiscoveredDevice) {
        var c = config
        c.peripheralUUID = d.id; c.peripheralName = d.name; c.enabled = true
        update(c)
    }

    func start() { reloadConfig() }

    // MARK: 运行状态切换

    private func applyRunningState() {
        queue.async {
            guard self.central.state == .poweredOn else { return }
            let bound = !self.config.peripheralUUID.isEmpty
            if self.config.enabled && bound {
                self.tryRetrieveKnownThenScan()
            } else {
                self.central.stopScan()
                if let t = self.target { self.central.cancelPeripheralConnection(t) }
                self.target = nil
                self.stopRssiLoop()
                self.cancelPendingLock()
                self.cancelDisconnectGrace()
                self.engine.reset()
                DispatchQueue.main.async {
                    self.state.connected = false; self.state.scanning = false
                    self.state.zone = self.config.enabled ? "unbound" : "searching"
                    self.state.rssi = 0
                }
            }
        }
    }

    // MARK: 扫描 / 连接

    private func ensureScanning() {
        guard central.state == .poweredOn, !central.isScanning else { return }
        central.scanForPeripherals(withServices: nil,
                                   options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
        DispatchQueue.main.async { self.state.scanning = true }
    }

    private func tryRetrieveKnownThenScan() {
        let uuid = config.peripheralUUID
        guard !uuid.isEmpty else {
            DispatchQueue.main.async { self.state.zone = "unbound" }
            return
        }
        if let u = UUID(uuidString: uuid) {
            let known = central.retrievePeripherals(withIdentifiers: [u])
            if let p = known.first { connect(p); return }
        }
        ensureScanning()
    }

    private func connect(_ p: CBPeripheral) {
        target = p
        p.delegate = self
        central.stopScan()
        DispatchQueue.main.async { self.state.scanning = false }
        central.connect(p, options: [
            CBConnectPeripheralOptionNotifyOnConnectionKey: true,
            CBConnectPeripheralOptionNotifyOnDisconnectionKey: true
        ])
    }

    // MARK: RSSI 循环

    private func startRssiLoop() {
        rssiTimer?.cancel()
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 0.5, repeating: 0.5)
        t.setEventHandler { [weak self] in self?.target?.readRSSI() }
        rssiTimer = t; t.resume()
    }
    private func stopRssiLoop() { rssiTimer?.cancel(); rssiTimer = nil }

    // MARK: 候选设备防抖刷新

    private func startCandidateFlush() {
        candidateFlushTimer?.cancel()
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 1.5, repeating: 1.5)
        t.setEventHandler { [weak self] in
            guard let self else { return }
            let items = Array(self.candidateBuffer.values).sorted { $0.rssi > $1.rssi }
            DispatchQueue.main.async { self.pairCandidates = items }
        }
        candidateFlushTimer = t; t.resume()
    }
    private func stopCandidateFlush() {
        candidateFlushTimer?.cancel(); candidateFlushTimer = nil
        // 最后刷一次
        let items = Array(candidateBuffer.values).sorted { $0.rssi > $1.rssi }
        DispatchQueue.main.async { self.pairCandidates = items }
    }

    // MARK: 延迟锁定 / 宽限期

    private func schedulePendingLock() {
        cancelPendingLock()
        let delay = TimeInterval(config.lockDelay)
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + delay)
        t.setEventHandler { [weak self] in
            guard let self else { return }
            // 延迟到期：如果设备仍在远处、且用户没有手动解锁过，则锁屏
            if self.engine.currentZone == .far && !self.userUnlockedWhileAway {
                if self.config.autoLock, !ScreenLocker.shared.isLocked {
                    DispatchQueue.main.async { ScreenLocker.shared.lockNow() }
                }
            }
        }
        pendingLockTimer = t; t.resume()
    }
    private func cancelPendingLock() { pendingLockTimer?.cancel(); pendingLockTimer = nil }

    private func scheduleDisconnectGrace() {
        cancelDisconnectGrace()
        let delay = TimeInterval(config.lockDelay)
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + delay)
        t.setEventHandler { [weak self] in
            guard let self else { return }
            // 宽限期到：仍未重连 → 发通知 + 锁屏（如果用户没手动解锁过）
            if !self.state.connected {
                self.postSignalLostNotification()
                if self.config.autoLock, !self.userUnlockedWhileAway,
                   !ScreenLocker.shared.isLocked {
                    DispatchQueue.main.async { ScreenLocker.shared.lockNow() }
                }
                // 继续尝试重连
                self.tryRetrieveKnownThenScan()
            }
        }
        disconnectGraceTimer = t; t.resume()
    }
    private func cancelDisconnectGrace() { disconnectGraceTimer?.cancel(); disconnectGraceTimer = nil }

    // MARK: 距离判定 → 动作

    private func ingest(rssi: Int) {
        switch engine.ingest(rssi) {
        case .none:
            DispatchQueue.main.async { self.state.rssi = self.engine.smoothed }
        case .lock:
            // 进入远处：启动延迟锁定 timer（不立即锁）
            DispatchQueue.main.async {
                self.state.zone = "far"; self.state.rssi = self.engine.smoothed
            }
            if config.autoLock, !userUnlockedWhileAway {
                schedulePendingLock()
            }
        case .unlock:
            // 进入近处：取消延迟锁定 + 清除手动解锁标志 + 触发解锁
            cancelPendingLock()
            userUnlockedWhileAway = false
            DispatchQueue.main.async {
                self.state.zone = "near"; self.state.rssi = self.engine.smoothed
            }
            tryAutoUnlock()
        }
    }

    /// 尝试自动解锁：唤醒显示器 → 等密码框就绪 → 输入密码
    private func tryAutoUnlock() {
        guard config.autoUnlock, ScreenLocker.shared.isLocked else { return }
        DispatchQueue.main.async {
            ScreenLocker.shared.wakeDisplay()
            // 等显示器唤醒 + 密码框聚焦（BLEUnlock 保守延迟原理）
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                ScreenLocker.shared.autoUnlockFromKeychain()
            }
        }
    }

    // MARK: 信号丢失通知

    private func postSignalLostNotification() {
        let content = UNMutableNotificationContent()
        content.title = "信号丢失"
        content.body = "设备已超出阈值范围"
        content.sound = .default
        let req = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req)
    }
}

// MARK: - Central 代理

extension ProximityLock: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        DispatchQueue.main.async { self.state.powered = central.state == .poweredOn }
        switch central.state {
        case .poweredOn: applyRunningState()
        case .resetting, .unknown: break
        default:
            stopRssiLoop()
            cancelPendingLock()
            cancelDisconnectGrace()
            DispatchQueue.main.async {
                self.state.connected = false
                self.state.zone = self.config.enabled ? "unbound" : "searching"
            }
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let name = peripheral.name
            ?? (advertisementData[CBAdvertisementDataLocalNameKey] as? String)
            ?? "未知设备"

        // 配对模式：收集到缓冲（防抖批量刷新）
        if pairingMode {
            let d = DiscoveredDevice(id: peripheral.identifier.uuidString, name: name, rssi: RSSI.intValue)
            candidateBuffer[d.id] = d
        }

        // 自动模式：只连接已绑定的目标设备
        if config.enabled, peripheral.identifier.uuidString == config.peripheralUUID {
            connect(peripheral)
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        cancelDisconnectGrace()
        cancelPendingLock()
        // 设备回近：清除手动解锁暂停标志
        userUnlockedWhileAway = false
        queue.async { self.engine.reset(); self.engine.markConnectedBaseline() }
        DispatchQueue.main.async {
            self.state.connected = true
            self.state.deviceName = self.config.peripheralName
            self.state.zone = "near"
        }
        startRssiLoop()
        // BLEUnlock 原理：连接建立即触发解锁（不等 RSSI 判定）
        tryAutoUnlock()
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        stopRssiLoop()
        queue.async { self.engine.reset() }
        DispatchQueue.main.async {
            self.state.connected = false; self.state.rssi = 0; self.state.zone = "searching"
        }
        guard config.enabled, !config.peripheralUUID.isEmpty else { return }
        // 断开：启动宽限期 timer（延迟锁定 + 发通知），同时尝试重连
        scheduleDisconnectGrace()
        // 1.5 秒后尝试重连
        queue.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self, self.config.enabled, !self.state.connected else { return }
            self.tryRetrieveKnownThenScan()
        }
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        queue.asyncAfter(deadline: .now() + 2) { [weak self] in self?.tryRetrieveKnownThenScan() }
    }
}

// MARK: - Peripheral 代理

extension ProximityLock: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didReadRSSI RSSI: NSNumber, error: Error?) {
        guard error == nil else { return }
        ingest(rssi: RSSI.intValue)
    }
}
