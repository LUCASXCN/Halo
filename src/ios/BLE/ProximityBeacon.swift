//
//  ProximityBeacon.swift — iPhone 作 BLE 外设广播，供 Mac 测 RSSI 判距离
//  ─────────────────────────────────────────────────────────────────
//  融合 BLEUnlock 思路：iPhone 只负责持续广播一个固定 Service 并接受 Mac 连接，
//  RSSI 的测量、靠近/远离判定、自动锁屏/解锁全部在 Mac 端完成。
//

import Foundation
import CoreBluetooth
import Combine
#if canImport(UIKit)
import UIKit
#endif

@MainActor
final class ProximityBeacon: NSObject, ObservableObject {
    @Published var powered = false
    @Published var advertising = false
    @Published var connected = false
    @Published var statusText = "未开启"

    private var manager: CBPeripheralManager!
    private var service: CBMutableService?
    private let serviceUUID = CBUUID(string: Halo.bleService)
    private let keepUUID = CBUUID(string: Halo.bleKeepChar)

    override init() {
        super.init()
        // 初始不弹蓝牙授权，等用户在「靠近」页显式开启
    }

    func start() {
        if manager == nil {
            manager = CBPeripheralManager(delegate: self, queue: nil)
        }
        if manager.state == .poweredOn { beginAdvertise() }
        statusText = "正在启动…"
    }

    func stop() {
        guard let manager else { return }
        manager.stopAdvertising()
        if let s = service { manager.remove(s) }
        advertising = false; connected = false
        statusText = "已停止"
    }

    private func setupService() {
        let keep = CBMutableCharacteristic(type: keepUUID,
                                          properties: [.read, .notify],
                                          value: Data("halo".utf8),
                                          permissions: [.readable])
        let s = CBMutableService(type: serviceUUID, primary: true)
        s.characteristics = [keep]
        service = s
        manager.removeAllServices()
        manager.add(s)
    }

    private func beginAdvertise() {
        setupService()
        manager.startAdvertising([
            CBAdvertisementDataServiceUUIDsKey: [serviceUUID],
            CBAdvertisementDataLocalNameKey: deviceShortName
        ])
        advertising = true
        powered = true
        statusText = "正在广播，等待 Mac 连接"
    }

    private var deviceShortName: String {
        #if canImport(UIKit)
        return UIDevice.current.name
        #else
        return Host.current().localizedName ?? "iPhone"
        #endif
    }
}

extension ProximityBeacon: CBPeripheralManagerDelegate {
    nonisolated func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        Task { @MainActor in
            self.powered = peripheral.state == .poweredOn
            switch peripheral.state {
            case .poweredOn:
                if !self.advertising { self.beginAdvertise() }
            case .unauthorized: self.statusText = "请在系统设置允许蓝牙权限"
            case .poweredOff: self.statusText = "请打开蓝牙"; self.advertising = false
            default: self.statusText = "蓝牙不可用：\(peripheral.state.rawValue)"
            }
        }
    }

    nonisolated func peripheralManagerDidStartAdvertising(_ peripheral: CBPeripheralManager, error: Error?) {
        Task { @MainActor in
            if let error { self.statusText = "广播失败：\(error.localizedDescription)"; self.advertising = false }
            else { self.advertising = true; self.statusText = "正在广播，等待 Mac 连接" }
        }
    }

    nonisolated func peripheralManager(_ peripheral: CBPeripheralManager, central: CBCentral, didSubscribeTo characteristic: CBCharacteristic) {
        Task { @MainActor in
            self.connected = true
            self.statusText = "已连接到 Mac（正在持续测距）"
        }
    }

    nonisolated func peripheralManager(_ peripheral: CBPeripheralManager, central: CBCentral, didUnsubscribeFrom characteristic: CBCharacteristic) {
        Task { @MainActor in
            self.connected = false
            self.statusText = "Mac 已断开，继续广播"
        }
    }
}
