//
//  ProximityLock.swift — 蓝牙靠近解锁（Mac 作为中央端，融合 BLEUnlock 测距原理）
//  ─────────────────────────────────────────────────────────────────────────────
//  iPhone 端 HaloRemote 作为 BLE 外设广播专属 Service；Mac 扫描→连接→周期读取
//  RSSI，用「滑窗平均 + 双阈值迟滞 + 驻留时间」判定 near/far，避免边界抖动：
//    · 平均 RSSI 低于 awayRSSI 并持续 dwell → far：自动锁屏
//    · far 之后平均 RSSI 高于 nearRSSI 并持续 dwell → near：自动输密码解锁
//    · 连接断开且超时未恢复，视同远离（自动锁）
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

    private var central: CBCentralManager!
    private var target: CBPeripheral?
    private var queue = DispatchQueue(label: "com.lucas.halo.ble", qos: .userInitiated)

    private var rssiWindow: [Int] = []
    private let windowMax = 8
    private var rssiTimer: DispatchSourceTimer?
    private var candidateFarAt: Date?
    private var candidateNearAt: Date?
    private var zone: Zone = .searching
    private var disconnectAt: Date?
    private var pairingMode = false

    private enum Zone { case searching, near, far }

    private override init() {
        super.init()
        config = HaloStore.shared.loadProximity()
        central = CBCentralManager(delegate: self, queue: queue)
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
            self.resetHysteresis()
            self.applyRunningState()
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
            if self.config.enabled {
                self.tryRetrieveKnownThenScan()
            } else {
                self.central.stopScan()
                if let t = self.target { self.central.cancelPeripheralConnection(t) }
                self.target = nil
                DispatchQueue.main.async {
                    self.state.connected = false; self.state.scanning = false
                    self.state.zone = "searching"; self.state.rssi = 0
                }
                self.stopRssiLoop()
            }
        }
    }

    // MARK: 扫描 / 连接

    private func ensureScanning() {
        guard central.state == .poweredOn, !central.isScanning else { return }
        central.scanForPeripherals(withServices: [CBUUID(string: Halo.bleService)],
                                   options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
        DispatchQueue.main.async { self.state.scanning = true }
    }

    private func tryRetrieveKnownThenScan() {
        let uuid = config.peripheralUUID
        if !uuid.isEmpty, let u = UUID(uuidString: uuid) {
            let known = central.retrievePeripherals(withIdentifiers: [u])
            if let p = known.first { connect(p); return }
        }
        // 已连接系统级设备（同 iCloud 账号）也可直接取回
        let connected = central.retrieveConnectedPeripherals(withServices: [CBUUID(string: Halo.bleService)])
        if let p = connected.first(where: { $0.identifier.uuidString == uuid || uuid.isEmpty }) {
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

    private func resetHysteresis() {
        candidateFarAt = nil; candidateNearAt = nil; rssiWindow.removeAll()
    }

    // MARK: 距离判定

    private func ingest(rssi: Int) {
        rssiWindow.append(rssi)
        if rssiWindow.count > windowMax { rssiWindow.removeFirst() }
        let smoothed = rssiWindow.reduce(0, +) / max(1, rssiWindow.count)
        DispatchQueue.main.async { self.state.rssi = smoothed }
        guard rssiWindow.count >= 3 else { return }

        let now = Date()
        let dwell = config.dwellSeconds

        switch zone {
        case .searching, .near:
            // 近 → 远
            if smoothed <= config.awayRSSI {
                if candidateFarAt == nil { candidateFarAt = now }
                if let at = candidateFarAt, now.timeIntervalSince(at) >= dwell {
                    enterFar()
                }
            } else { candidateFarAt = nil }
            if smoothed >= config.nearRSSI, zone == .searching { enterNear(reset: false) }
        case .far:
            // 远 → 近（迟滞：必须高于更高的 near 阈值）
            if smoothed >= config.nearRSSI {
                if candidateNearAt == nil { candidateNearAt = now }
                if let at = candidateNearAt, now.timeIntervalSince(at) >= dwell {
                    enterNear(reset: true)
                }
            } else { candidateNearAt = nil }
        }
    }

    private func enterFar() {
        zone = .far; resetHysteresis()
        DispatchQueue.main.async {
            self.state.zone = "far"
            guard self.config.autoLock else { return }
            if !ScreenLocker.shared.isLocked { ScreenLocker.shared.lockNow() }
        }
    }

    private func enterNear(reset: Bool) {
        zone = .near
        if reset { resetHysteresis() }
        DispatchQueue.main.async {
            self.state.zone = "near"
            guard self.config.autoUnlock else { return }
            if ScreenLocker.shared.isLocked {
                ScreenLocker.shared.autoUnlockFromKeychain()
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
            DispatchQueue.main.async { self.state.connected = false; self.state.zone = "searching" }
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
        } else if config.enabled, config.peripheralUUID.isEmpty {
            // 未绑定不自动连，避免误锁
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        disconnectAt = nil; zone = .searching; resetHysteresis()
        peripheral.discoverServices([CBUUID(string: Halo.bleService)])
        DispatchQueue.main.async {
            self.state.connected = true
            self.state.deviceName = self.config.peripheralName.isEmpty ? (peripheral.name ?? "iPhone") : self.config.peripheralName
            self.state.zone = "near"
            self.zone = .near
        }
        startRssiLoop()
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        stopRssiLoop()
        DispatchQueue.main.async {
            self.state.connected = false; self.state.rssi = 0; self.state.zone = "searching"
        }
        guard config.enabled else { return }
        // 断开视同远离：给一个宽限窗口尝试重连，仍失败则锁屏
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
        // 发现服务即可，RSSI 不依赖特征；发现保活特征以维持稳定连接
        guard let services = peripheral.services else { return }
        for s in services where s.uuid == CBUUID(string: Halo.bleService) {
            peripheral.discoverCharacteristics([CBUUID(string: Halo.bleKeepChar)], for: s)
        }
    }
    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {}

    func peripheral(_ peripheral: CBPeripheral, didReadRSSI RSSI: NSNumber, error: Error?) {
        guard error == nil else { return }
        ingest(rssi: RSSI.intValue)
    }
}
