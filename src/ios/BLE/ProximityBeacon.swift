//
//  ProximityBeacon.swift — iPhone 作 BLE 外设广播，供 Mac 测 RSSI 判距离
//  ─────────────────────────────────────────────────────────────────
//  融合 BLEUnlock 思路：iPhone 只负责持续广播一个固定 Service 并接受 Mac 连接，
//  RSSI 的测量、靠近/远离判定、自动锁屏/解锁全部在 Mac 端完成。
//
//  稳定性设计（曾两次崩溃：①非法 UUID 启动即崩 ②重复 addService 断言崩）：
//    · 完全惰性：init 不碰 CoreBluetooth，只有用户在「靠近」页显式开启才初始化；
//    · 所有 CBUUID 经 CBUUID.halo() 安全构造，非法字符串永不导致崩溃；
//    · 严格状态机：idle → initializing → addingService → advertising → stopping，
//      任何时刻只允许一条推进路径，杜绝 start()/didUpdateState 重入导致重复 addService；
//    · addService 异步完成后才 startAdvertising（通过 didAddService 回调），
//      不在 service 尚未注册时就广播；
//    · 任何蓝牙错误只更新 statusText，绝不允许 abort / fatalError 拖垮 App。
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

    // MARK: - 内部状态机

    private enum Phase {
        case idle           // 未启动或已停止
        case initializing   // manager 已创建，等待 poweredOn 回调
        case addingService  // 已调用 addService，等待 didAddService 回调
        case advertising    // 正在广播
        case stopping       // 正在停止（防止 stop 过程中被重启）
    }

    private var phase: Phase = .idle
    private var manager: CBPeripheralManager?
    private var service: CBMutableService?
    private var serviceUUID: CBUUID?

    override init() {
        super.init()
        // 完全惰性：init 不构造任何 CBUUID / CBPeripheralManager
    }

    // MARK: - 对外控制

    /// 用户点「开启广播」。幂等：已在广播或正在启动中则直接忽略。
    func start() {
        switch phase {
        case .idle:
            phase = .initializing
            statusText = "正在启动蓝牙…"
            let mgr = CBPeripheralManager(delegate: self, queue: nil)
            manager = mgr
            // 极少数情况下 manager 创建后 state 立即可用（蓝牙已开+权限已授）
            if mgr.state == .poweredOn {
                // 同步推进到 addingService，避免等 didUpdateState 又触发一次
                beginAddService()
            }
        case .initializing, .addingService, .advertising, .stopping:
            // 已在流程中，忽略重复调用
            break
        }
    }

    /// 用户点「停止广播」。
    func stop() {
        guard let mgr = manager else {
            phase = .idle
            advertising = false
            connected = false
            statusText = "已停止"
            return
        }
        phase = .stopping
        mgr.stopAdvertising()
        if let s = service { mgr.remove(s) }
        service = nil
        serviceUUID = nil
        advertising = false
        connected = false
        powered = mgr.state == .poweredOn
        statusText = "已停止"
        phase = .idle
    }

    // MARK: - 内部推进

    /// 状态机推进：从 initializing → addingService。
    /// 只在 manager 存在且 poweredOn 时调用。
    private func beginAddService() {
        guard let mgr = manager, mgr.state == .poweredOn else { return }
        guard phase == .initializing else { return }

        phase = .addingService
        statusText = "正在注册蓝牙服务…"

        // 安全构造 UUID（非法时回退到固定合法值，绝不崩）
        let svcUUID = CBUUID.halo(Halo.bleService)
        let keepUUID = CBUUID.halo(Halo.bleKeepChar)
        self.serviceUUID = svcUUID

        let keep = CBMutableCharacteristic(
            type: keepUUID,
            properties: [.read, .notify],
            value: Data("halo".utf8),
            permissions: [.readable]
        )
        let s = CBMutableService(type: svcUUID, primary: true)
        s.characteristics = [keep]
        service = s

        // 先清掉旧 service（如果有），再添加新的
        mgr.removeAllServices()
        mgr.add(s)
        // 注意：不在这里 startAdvertising，等 didAddService 回调确认成功后再广播
    }

    /// 状态机推进：从 addingService → advertising。
    /// 在 didAddService 成功回调中调用。
    private func beginAdvertising() {
        guard let mgr = manager, mgr.state == .poweredOn else { return }
        guard phase == .addingService, let svc = serviceUUID else { return }

        phase = .advertising
        mgr.startAdvertising([
            CBAdvertisementDataServiceUUIDsKey: [svc],
            CBAdvertisementDataLocalNameKey: deviceShortName
        ])
        // advertising 标志在 didStartAdvertising 回调中最终确认
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

// MARK: - CBPeripheralManagerDelegate

extension ProximityBeacon: CBPeripheralManagerDelegate {

    nonisolated func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        Task { @MainActor in
            self.powered = peripheral.state == .poweredOn
            switch peripheral.state {
            case .poweredOn:
                // 只有在 initializing 阶段才推进；如果已经在 addingService/advertising，
                // 说明 start() 同步路径已经推进过了，这里不再重复触发。
                if self.phase == .initializing {
                    self.beginAddService()
                }
            case .unauthorized:
                self.statusText = "请在系统设置允许蓝牙权限"
                self.phase = .idle
            case .poweredOff:
                self.statusText = "请打开蓝牙"
                self.advertising = false
                self.phase = .idle
            case .resetting, .unknown:
                self.statusText = "蓝牙正在初始化…"
            default:
                self.statusText = "蓝牙不可用：\(peripheral.state.rawValue)"
                self.phase = .idle
            }
        }
    }

    nonisolated func peripheralManager(_ peripheral: CBPeripheralManager,
                                        didAdd service: CBService,
                                        error: Error?) {
        Task { @MainActor in
            if let error = error {
                // service 添加失败：回退到 idle，更新状态，绝不崩溃
                self.statusText = "蓝牙服务注册失败：\(error.localizedDescription)"
                self.phase = .idle
                self.service = nil
                self.serviceUUID = nil
                return
            }
            // service 注册成功 → 开始广播
            if self.phase == .addingService {
                self.beginAdvertising()
            }
        }
    }

    nonisolated func peripheralManagerDidStartAdvertising(_ peripheral: CBPeripheralManager,
                                                            error: Error?) {
        Task { @MainActor in
            if let error = error {
                self.statusText = "广播失败：\(error.localizedDescription)"
                self.advertising = false
                self.phase = .idle
            } else {
                self.advertising = true
                self.statusText = "正在广播，等待 Mac 连接"
            }
        }
    }

    nonisolated func peripheralManager(_ peripheral: CBPeripheralManager,
                                        central: CBCentral,
                                        didSubscribeTo characteristic: CBCharacteristic) {
        Task { @MainActor in
            self.connected = true
            self.statusText = "已连接到 Mac（正在持续测距）"
        }
    }

    nonisolated func peripheralManager(_ peripheral: CBPeripheralManager,
                                        central: CBCentral,
                                        didUnsubscribeFrom characteristic: CBCharacteristic) {
        Task { @MainActor in
            self.connected = false
            self.statusText = "Mac 已断开，继续广播"
        }
    }
}
