//
//  ProximityView.swift — 蓝牙靠近联动（手机广播端）
//

import SwiftUI

struct ProximityView: View {
    @ObservedObject var model: AppModel
    @State private var cfg = ProximityConfig()
    @State private var loaded = false

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                beaconCard
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
    }

    private var beaconCard: some View {
        VStack(spacing: 14) {
            Image(systemName: model.beacon.connected ? "antenna.radiowaves.left.and.right" : "antenna.radiowaves.left.and.right.slash")
                .font(.system(size: 48, weight: .medium))
                .foregroundStyle(model.beacon.advertising ? .green : .secondary)
                .padding(24).haloGlass(corner: 32)
            Text(model.beacon.statusText).font(.headline)
            Toggle(isOn: Binding(get: { model.beacon.advertising }, set: { on in
                if on { model.beacon.start() } else { model.beacon.stop() }
            })) {
                Text("开启蓝牙靠近广播").font(.subheadline.weight(.semibold))
            }
            .toggleStyle(.switch)
        }
        .padding(22)
        .frame(maxWidth: .infinity)
        .haloGlass()
    }

    private var configCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionTitle(icon: "slider.horizontal.3", text: "距离阈值（同步到 Mac）")
            Toggle("远离自动锁屏", isOn: $cfg.autoLock)
            Toggle("靠近自动输入密码解锁", isOn: $cfg.autoUnlock)
            thresholdRow("远离阈值", value: $cfg.awayRSSI, range: -90...(-60))
            thresholdRow("靠近阈值", value: $cfg.nearRSSI, range: -70...(-40))
            Text("数值越小（越负）表示距离越远才触发。例如远离 -70、靠近 -55。")
                .font(.caption).foregroundStyle(.secondary)
            GlassPrimaryButton(title: "同步设置到 Mac", systemImage: "arrow.up.circle") {
                Task { await model.saveProximity(cfg) }
            }
        }
        .padding(18)
        .haloGlass()
    }

    private var explainCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionTitle(icon: "questionmark.circle", text: "如何使用")
            VStack(alignment: .leading, spacing: 6) {
                Text("1. 在 Mac 端 Halo「iPhone 联动」页保存登录密码（仅存钥匙串）。")
                Text("2. 本页开启蓝牙广播，并在 Mac 端点「绑定我的 iPhone」。")
                Text("3. 携带手机离开 → 自动锁屏；回到附近 → 自动输入密码解锁。")
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
}
