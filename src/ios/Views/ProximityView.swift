//
//  ProximityView.swift — 靠近解锁（iPhone 端仅做 Wi-Fi 远程开关 + 状态显示）
//  ─────────────────────────────────────────────────────────────────
//  蓝牙测距完全在 Mac 端完成：Mac 扫描 iPhone 系统蓝牙 → 连接 → 读 RSSI → 判定距离。
//  iPhone 不需要装任何蓝牙代码。本页通过 Wi-Fi 查看 Mac 蓝牙状态、远程开关
//  「远离自动锁屏」「靠近自动解锁」、同步距离阈值。
//

import SwiftUI

struct ProximityView: View {
    @ObservedObject var model: AppModel
    @State private var cfg = ProximityConfig()
    @State private var loaded = false

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                statusCard
                configCard
                explainCard
            }
            .padding(20)
        }
        .background(HaloBackground())
        .task {
            if !loaded, let c = try? await model.client.getProximity() {
                cfg = c; loaded = true
            }
        }
        .onReceive(model.$ping) { p in
            if let p { cfg = p.proximity }
        }
    }

    // MARK: Mac 蓝牙实时状态
    private var statusCard: some View {
        VStack(spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: statusIcon)
                    .font(.system(size: 36, weight: .medium))
                    .foregroundStyle(statusColor)
                    .padding(20).haloGlass(corner: 28)
                VStack(alignment: .leading, spacing: 4) {
                    Text(statusTitle).font(.headline)
                    Text(statusDetail).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }
            if let ble = model.ping?.ble, ble.connected {
                HStack {
                    Text("信号强度").font(.subheadline).foregroundStyle(.secondary)
                    Spacer()
                    Text("\(ble.rssi) dBm").font(.subheadline.weight(.semibold).monospaced())
                    Text(zoneCN(ble.zone)).font(.caption).foregroundStyle(zoneColor(ble.zone))
                }
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(RoundedRectangle(cornerRadius: 12).fill(.white.opacity(0.06)))
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity)
        .haloGlass()
    }

    private var statusIcon: String {
        guard let ble = model.ping?.ble, model.ping?.proximity.enabled == true else {
            return "antenna.radiowaves.left.and.right.slash"
        }
        if ble.connected { return "antenna.radiowaves.left.and.right" }
        if ble.powered { return "magnifyingglass" }
        return "antenna.radiowaves.left.and.right.slash"
    }

    private var statusColor: Color {
        guard let ble = model.ping?.ble, model.ping?.proximity.enabled == true else { return .secondary }
        if ble.connected { return ble.zone == "near" ? .green : .orange }
        return .yellow
    }

    private var statusTitle: String {
        guard let p = model.ping else { return "未连接 Mac" }
        if !p.proximity.enabled { return "靠近解锁未启用" }
        if p.ble.connected { return p.ble.zone == "near" ? "已连接 · 在附近" : "已连接 · 已远离" }
        if p.ble.powered { return "正在搜索你的 iPhone…" }
        return "Mac 蓝牙未开启"
    }

    private var statusDetail: String {
        guard let p = model.ping else { return "请先在「遥控」页连接 Mac" }
        if !p.proximity.enabled { return "在下方开启总开关并在 Mac 端绑定设备" }
        if !p.proximity.peripheralName.isEmpty { return "已绑定：\(p.proximity.peripheralName)" }
        return "请在 Mac 端「iPhone 联动」页绑定你的 iPhone"
    }

    // MARK: 远程开关 + 阈值
    private var configCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionTitle(icon: "slider.horizontal.3", text: "远程设置（同步到 Mac）")

            Toggle(isOn: Binding(get: { cfg.enabled }, set: { cfg.enabled = $0; sync() })) {
                Text("启用靠近自动解锁 / 远离自动锁屏").font(.subheadline.weight(.semibold))
            }

            Toggle(isOn: Binding(get: { cfg.autoLock }, set: { cfg.autoLock = $0; sync() })) {
                Text("远离自动锁屏").font(.subheadline)
            }

            Toggle(isOn: Binding(get: { cfg.autoUnlock }, set: { cfg.autoUnlock = $0; sync() })) {
                Text("靠近自动输入密码解锁").font(.subheadline)
            }

            thresholdRow("远离阈值", value: $cfg.awayRSSI, range: -90...(-60))
            thresholdRow("靠近阈值", value: $cfg.nearRSSI, range: -75...(-35))

            // 延迟锁定
            VStack(alignment: .leading, spacing: 6) {
                Text("延迟锁定").font(.subheadline)
                HStack(spacing: 8) {
                    ForEach([5, 10, 15, 30], id: \.self) { sec in
                        Button(action: { cfg.lockDelay = sec; sync() }) {
                            Text("\(sec)秒")
                                .font(.subheadline.weight(.medium))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 10)
                                .background(RoundedRectangle(cornerRadius: 10)
                                    .fill(cfg.lockDelay == sec ? Color.blue.opacity(0.25) : Color.white.opacity(0.06)))
                                .overlay(RoundedRectangle(cornerRadius: 10)
                                    .stroke(cfg.lockDelay == sec ? Color.blue : Color.clear, lineWidth: 1.5))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            Text("数值越小（越负）表示距离越远才触发。例如远离 -70、靠近 -55。延迟锁定指超过阈值后等待指定秒数才锁屏。")
                .font(.caption).foregroundStyle(.secondary)

            GlassPrimaryButton(title: "同步设置到 Mac", systemImage: "arrow.up.circle") {
                sync()
            }
        }
        .padding(18)
        .haloGlass()
    }

    private func sync() {
        var c = cfg
        c.normalize()
        cfg = c
        Task { await model.saveProximity(c) }
    }

    // MARK: 使用说明
    private var explainCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionTitle(icon: "questionmark.circle", text: "如何使用")
            VStack(alignment: .leading, spacing: 6) {
                Text("1. 在 Mac 端 Halo「iPhone 联动」页保存登录密码（仅存钥匙串）。")
                Text("2. 在 Mac 端点「绑定我的 iPhone」，从扫描列表选择你的设备。")
                Text("3. 携带手机离开 → Mac 自动锁屏；回到附近 → 自动输入密码解锁。")
                Text("4. iPhone 端不需要开启任何蓝牙功能，Mac 直接检测手机系统蓝牙信号。")
            }
            .font(.footnote).foregroundStyle(.secondary)
        }
        .padding(18)
        .haloGlass()
    }

    private func thresholdRow(_ title: String, value: Binding<Int>, range: ClosedRange<Int>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack { Text(title).font(.subheadline); Spacer(); Text("\(value.wrappedValue) dBm").font(.subheadline.monospaced()) }
            Slider(value: Binding(get: { Double(value.wrappedValue) },
                                  set: { value.wrappedValue = Int($0) }),
                   in: Double(range.lowerBound)...Double(range.upperBound), step: 1)
        }
    }

    private func zoneCN(_ z: String) -> String {
        ["close": "很近", "near": "在附近", "far": "已远离", "searching": "搜索中"][z] ?? z
    }
    private func zoneColor(_ z: String) -> Color {
        ["near": .green, "close": .green, "far": .orange][z] ?? .secondary
    }
}
