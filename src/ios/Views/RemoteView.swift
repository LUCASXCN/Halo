//
//  RemoteView.swift — 手动锁屏 + Mac 实时状态
//

import SwiftUI

struct RemoteView: View {
    @ObservedObject var model: AppModel
    private var ping: PingResponse? { model.ping }

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                lockCard
                statusCard
                proximityHint
            }
            .padding(20)
        }
        .background(HaloBackground())
    }

    private var lockCard: some View {
        let locked = ping?.locked ?? false
        return VStack(spacing: 16) {
            Image(systemName: locked ? "lock.fill" : "lock.open.fill")
                .font(.system(size: 54, weight: .medium))
                .foregroundStyle(locked ? .blue : .orange)
                .padding(26)
                .haloGlass(corner: 34)
            Text(locked ? "Mac 当前已锁定" : "Mac 当前未锁定")
                .font(.headline)
            if locked {
                GlassPrimaryButton(title: "解锁 Mac", systemImage: "lock.open.fill", tint: .blue) {
                    Task { await model.unlockNow() }
                }
            } else {
                GlassPrimaryButton(title: "立即锁定 Mac", systemImage: "lock.fill", tint: .orange) {
                    Task { await model.lockNow() }
                }
            }
        }
        .padding(22)
        .frame(maxWidth: .infinity)
        .haloGlass()
    }

    private var statusCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionTitle(icon: "info.circle", text: "Mac 状态")
            row("设备", model.macName)
            row("型号", ping?.model ?? "—")
            row("登录密码已存", (ping?.hasPassword ?? false) ? "是（可自动解锁）" : "否")
            row("桌面覆盖服务", (ping?.overlayRunning ?? false) ? "运行中" : "未运行",
                ok: ping?.overlayRunning ?? false)
            row("蓝牙", ping?.ble.powered ?? false ? "已开启" : "未开启",
                ok: ping?.ble.powered ?? false)
            if let z = ping?.ble.zone, z != "searching" {
                row("邻近状态", zoneCN(z), ok: z == "near" || z == "close")
            }
        }
        .padding(18)
        .haloGlass()
    }

    private var proximityHint: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionTitle(icon: "wave.3.right", text: "靠近自动解锁")
            Text("到「靠近」页开启手机蓝牙广播，并在 Mac 端绑定本机、设置阈值与登录密码，即可实现远离自动锁屏、靠近自动解锁。")
                .font(.footnote).foregroundStyle(.secondary)
        }
        .padding(18)
        .haloGlass()
    }

    private func row(_ k: String, _ v: String, ok: Bool? = nil) -> some View {
        HStack {
            Text(k).foregroundStyle(.secondary)
            Spacer()
            if let ok { StatusDot(ok: ok) }
            Text(v).font(.subheadline.weight(.medium))
        }
        .font(.subheadline)
    }

    private func zoneCN(_ z: String) -> String {
        ["close": "很近", "near": "在附近", "far": "已远离", "searching": "搜索中"][z] ?? z
    }
}
