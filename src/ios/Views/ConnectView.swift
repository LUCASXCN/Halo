//
//  ConnectView.swift — 发现并连接 Mac（配对码）
//

import SwiftUI
import Network

struct ConnectView: View {
    @ObservedObject var model: AppModel
    @State private var manualIP = ""
    @State private var manualPort = "\(Halo.defaultPort)"
    @State private var code = ""
    @State private var connecting = false
    @State private var err: String?

    private var client: HaloClient { model.client }

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                header
                pairCard
                discoveredCard
                manualCard
            }
            .padding(20)
        }
        .background(HaloBackground())
        .onAppear {
            code = client.pairCode
            manualIP = client.manualHost
            manualPort = client.manualPort
            client.startBrowsing()
        }
    }

    private var header: some View {
        VStack(spacing: 8) {
            Image(systemName: "dot.radiowaves.left.and.right")
                .font(.system(size: 46, weight: .medium))
                .foregroundStyle(.white)
                .padding(18)
                .haloGlass(corner: 28)
            Text("Halo 遥控").font(.title.bold())
            Text("让 iPhone 遥控 Mac 的锁屏与壁纸").font(.subheadline).foregroundStyle(.secondary)
        }
        .padding(.top, 24)
    }

    private var pairCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionTitle(icon: "key.fill", text: "配对码（Mac 端显示的 6 位数字）")
            TextField("625332", text: $code)
                .keyboardType(.numberPad)
                .font(.title3.monospaced())
                .padding(14)
                .background(RoundedRectangle(cornerRadius: 14).fill(.thinMaterial))
                .onChange(of: code) { _, v in
                    client.pairCode = String(v.filter { $0.isNumber }.prefix(6))
                }
        }
        .padding(18)
        .haloGlass()
    }

    private var discoveredCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                SectionTitle(icon: "wifi", text: "同一 Wi-Fi 下发现的 Mac")
                ProgressView().scaleEffect(0.8)
            }
            if client.discovered.isEmpty {
                Text("正在搜索…确认 Mac 端 Halo 已运行且与手机在同一 Wi-Fi")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            ForEach(client.discovered) { mac in
                Button {
                    Task { await connect(.bonjour(mac.endpoint), name: mac.name) }
                } label: {
                    HStack {
                        Image(systemName: "desktopcomputer")
                        VStack(alignment: .leading, spacing: 2) {
                            Text(mac.name).font(.body.weight(.medium))
                            Text("自动发现 · 点击连接").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(14)
                    .background(RoundedRectangle(cornerRadius: 14).fill(.thinMaterial))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(18)
        .haloGlass()
    }

    private var manualCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionTitle(icon: "slider.horizontal.3", text: "发现不了？手动输入 Mac 的 IP")
            HStack(spacing: 10) {
                TextField("192.168.31.32", text: $manualIP)
                    .keyboardType(.numbersAndPunctuation)
                    .textInputAutocapitalization(.never)
                    .padding(14)
                    .background(RoundedRectangle(cornerRadius: 14).fill(.thinMaterial))
                TextField("端口", text: $manualPort)
                    .keyboardType(.numberPad)
                    .frame(width: 76)
                    .padding(14)
                    .background(RoundedRectangle(cornerRadius: 14).fill(.thinMaterial))
            }
            GlassPrimaryButton(title: "连接", systemImage: "link") {
                let port = UInt16(manualPort) ?? Halo.defaultPort
                Task { await connect(.manual(host: manualIP, port: port), name: manualIP) }
            }
            if let err { Text(err).font(.footnote).foregroundStyle(.red) }
        }
        .padding(18)
        .haloGlass()
    }

    private func connect(_ t: HaloTarget, name: String) async {
        guard client.pairCode.count == 6 else { err = "请先输入 6 位配对码"; return }
        connecting = true; err = nil
        await model.connect(target: t, name: name)   // 失败原因由全局 toast 呈现
        connecting = false
    }
}
