//
//  ProximityLock.swift — 蓝牙靠近解锁（Mac 作为中央端，融合 BLEUnlock 测距原理）
//  ─────────────────────────────────────────────────────────────────────────────
//  iPhone 端 HaloRemote 作为 BLE 外设广播专属 Service；Mac 扫描→连接→周期读取
//  RSSI。距离判定全部在纯逻辑 ZoneDecisionEngine（可单测），本类只负责蓝牙收发与
//  在合适时机调用 ScreenLocker 锁屏/解锁。
//
//  稳定性原则（曾因非法 CBUUID 导致两端崩溃，此处做根治）：
//    · 所有 CBUUID 经 CBUUID.halo() 安全构造且只构造一次复用，绝不在热路径用字符串现建；
//    · 未绑定 iPhone（peripheralUUID 为空）时，即使总开关打开也不盲目后台扫描，
//      只有「已绑定自动连接」或「用户主动点配对扫描」才动蓝牙；
//    · 任何蓝牙回调异常都只更新状态文案，不允许拖垮主进程/菜单栏。
//

import Foundation
import CoreBluetooth
import Combine
import AppKit

final class ProximityLock: NSObject, ObservableObject {
    static let shared = ProximityLock()

    @Published var state = BLEStateInfo()
    @Published var config = ProximityConfig()
    /// 配对扫描期间发现的候选设备（供 UI 列表选择）
    @Published var pairCandidates: [DiscoveredDevice] = []

    struct DiscoveredDevice: Identifiable, Hashable {
        let id: String        // peripheral.identifier.uuidString
        let name: String
        let rssi: Int
    }

    // UUID 只构造一次（合法、安全），全类复用
    private let svcUUID = CBUUID.halo(Halo.bleService)
    private let keepUUID = CBUUID.halo(Halo.bleKeepChar)

    private var central: CBCentralManager!
    private var target: CBPeripheral?
    private var queue = DispatchQueue(label: "com.lucas.halo.ble", qos: .userInitiated)

    /// 纯逻辑判定引擎，仅在 queue 上访问
    private lazy var engine = ZoneDecisionEngine(awayRSSI: config.awayRSSI,
                                                 nearRSSI: config.nearRSSI,
                                                 dwellSeconds: config.dwellSeconds)
    private var rssiTimer: DispatchSourceTimer?
    private var disconnectAt: Date?
    private var pairingMode = false

    private override init() {
        super.init()
        config = HaloStore.shared.loadProximity()
        // 延迟到 runloop 之后再建中央端，避免 App 启动关键路径被蓝牙初始化阻塞
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
                // 同步引擎阈值并清掉历史迟滞，避免旧阈值下的候选时间干扰
                self.engine.awayRSSI = newConfig.awayRSSI
                self.engine.nearRSSI = newConfig.nearRSSI
                self.engine.dwellSeconds = newConfig.dwellSeconds
                self.engine.reset()
                self.applyRunningState()
            }
        }
    }

    /// UI：进入配对扫描，30s 内收集广播 Halo Service 的 iPhone
    func startPairing() {
        queue.async {
            self.pairingMode = true
            DispatchQueue.main.async { self.pairCandidates = [] }
            self.ensureScanning()
            DispatchQueue.main.asyncAfter(deadline: .now() + 30) { self.pairingMode = false }
        }
    }

    /// UI：选定某台 iPhone 作为绑定目标
    func pair(with d: DiscoveredDevice) {
        var c = config
        c.peripheralUUID = d.id; c.peripheralName = d.name; c.enabled = true
        update(c)
    }

    func start() { reloadConfig() }

    private func applyRunningState() {
        queue.async {
            guard self.central.state == .poweredOn else { return }
            let bound = !self.config.peripheralUUID.isEmpty
            if self.config.enabled && bound {
                self.tryRetrieveKnownThenScan()
            } else {
                // 未绑定或关闭：停止一切蓝牙活动，但不崩溃、不报错
                self.central.stopScan()
                if let t = self.target { self.central.cancelPeripheralConnection(t) }
                self.target = nil
                self.stopRssiLoop()
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
        central.scanForPeripherals(withServices: [svcUUID],
                                   options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
        DispatchQueue.main.async { self.state.scanning = true }
    }

    private func tryRetrieveKnownThenScan() {
        // 关键护栏：没有绑定设备就不自动扫描（杜绝「开了开关但没绑设备」时的无效/危险扫描）
        let uuid = config.peripheralUUID
        guard !uuid.isEmpty else {
            DispatchQueue.main.async { self.state.zone = "unbound" }
            return
        }
        if let u = UUID(uuidString: uuid) {
            let known = central.retrievePeripherals(withIdentifiers: [u])
            if let p = known.first { connect(p); return }
        }
        let connected = central.retrieveConnectedPeripherals(withServices: [svcUUID])
        if let p = connected.first(where: { $0.identifier.uuidString == uuid }) {
            connect(p); return
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

    // MARK: 距离判定 → 动作

    private func ingest(rssi: Int) {
        switch engine.ingest(rssi) {
        case .none:
            DispatchQueue.main.async { self.state.rssi = self.engine.smoothed }
        case .lock:
            DispatchQueue.main.async {
                self.state.zone = "far"; self.state.rssi = self.engine.smoothed
                guard self.config.autoLock else { return }
                if !ScreenLocker.shared.isLocked { ScreenLocker.shared.lockNow() }
            }
        case .unlock:
            DispatchQueue.main.async {
                self.state.zone = "near"; self.state.rssi = self.engine.smoothed
                guard self.config.autoUnlock else { return }
                if ScreenLocker.shared.isLocked {
                    ScreenLocker.shared.autoUnlockFromKeychain()
                }
            }
        }
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
            DispatchQueue.main.async {
                self.state.connected = false
                self.state.zone = self.config.enabled ? "unbound" : "searching"
            }
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let name = peripheral.name ?? (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? "iPhone"
        if pairingMode {
            let d = DiscoveredDevice(id: peripheral.identifier.uuidString, name: name, rssi: RSSI.intValue)
            DispatchQueue.main.async {
                self.pairCandidates.removeAll { $0.id == d.id }
                self.pairCandidates.append(d)
            }
        }
        // 自动模式：只连已绑定设备
        if config.enabled, peripheral.identifier.uuidString == config.peripheralUUID {
            connect(peripheral)
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        disconnectAt = nil
        queue.async { self.engine.reset(); self.engine.markConnectedBaseline() }
        peripheral.discoverServices([svcUUID])
        DispatchQueue.main.async {
            self.state.connected = true
            self.state.deviceName = self.config.peripheralName.isEmpty ? (peripheral.name ?? "iPhone") : self.config.peripheralName
            self.state.zone = "near"
        }
        startRssiLoop()
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        stopRssiLoop()
        queue.async { self.engine.reset() }
        DispatchQueue.main.async {
            self.state.connected = false; self.state.rssi = 0; self.state.zone = "searching"
        }
        guard config.enabled, !config.peripheralUUID.isEmpty else { return }
        // 断开视同远离：给宽限窗口尝试重连，仍失败则锁屏
        disconnectAt = Date()
        queue.asyncAfter(deadline: .now() + 9) { [weak self] in
            guard let self, self.target != nil, !self.state.connected else { return }
            if let at = self.disconnectAt, Date().timeIntervalSince(at) >= 8.5 {
                if self.config.autoLock, !ScreenLocker.shared.isLocked { ScreenLocker.shared.lockNow() }
                self.tryRetrieveKnownThenScan()
            }
        }
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
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard let services = peripheral.services else { return }
        for s in services where s.uuid == svcUUID {
            peripheral.discoverCharacteristics([keepUUID], for: s)
        }
    }
    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {}

    func peripheral(_ peripheral: CBPeripheral, didReadRSSI RSSI: NSNumber, error: Error?) {
        guard error == nil else { return }
        ingest(rssi: RSSI.intValue)
    }
}
