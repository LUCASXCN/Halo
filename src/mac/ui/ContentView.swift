//
//  ContentView.swift — Halo 主界面（Liquid Glass）：左双预览，右侧「壁纸 / iPhone 联动」双页
//
import SwiftUI
import AppKit

// MARK: - 玻璃容器

struct DragBar: NSViewRepresentable {
    final class Bar: NSView { override var mouseDownCanMoveWindow: Bool { true } }
    func makeNSView(context: Context) -> Bar { Bar() }
    func updateNSView(_ nsView: Bar, context: Context) {}
}

struct GlassPanel<Content: View>: View {
    var title: String? = nil
    @ObservedObject private var drag = DragMonitor.shared
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let title {
                Text(title).font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
            }
            content
        }
        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
        .modifier(RegularGlass(cornerRadius: 18, frozen: drag.isDragging))
    }
}

private struct RegularGlass: ViewModifier {
    let cornerRadius: CGFloat; let frozen: Bool
    func body(content: Content) -> some View {
        if frozen {
            content.background(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).fill(.white.opacity(0.10)))
        } else {
            content.glassEffect(.regular, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        }
    }
}
private struct ClearGlassBackdrop: ViewModifier {
    @ObservedObject var drag: DragMonitor
    func body(content: Content) -> some View {
        if drag.isDragging {
            content.background(RoundedRectangle(cornerRadius: 28, style: .continuous).fill(Color.black.opacity(0.52)))
        } else {
            content.glassEffect(.clear, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
        }
    }
}

// MARK: - 主视图

struct ContentView: View {
    @StateObject private var model = AppModel()
    @ObservedObject private var drag = DragMonitor.shared
    @State private var tab = 0
    private let rightWidth: CGFloat = 330

    var body: some View {
        ZStack {
            HStack(alignment: .top, spacing: 16) {
                leftColumn.frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity)
                rightColumn.frame(width: rightWidth).fixedSize(horizontal: true, vertical: false).layoutPriority(1)
            }
            .padding(.horizontal, 18).padding(.top, 40).padding(.bottom, 14)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .modifier(ClearGlassBackdrop(drag: drag))
            VStack(spacing: 0) { DragBar().frame(height: 40).frame(maxWidth: .infinity); Spacer(minLength: 0) }
        }
        .ignoresSafeArea()
        .onAppear { model.start() }
    }

    private var leftColumn: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Halo").font(.system(size: 21, weight: .bold))
                    Text("桌面 / 登录页分离 · iPhone 遥控与靠近解锁").font(.system(size: 12)).foregroundStyle(.secondary)
                }
                Spacer(); statusPill
            }
            PreviewCard(title: "桌面实际效果", tint: .blue, model: model, item: model.desktopItem) { DesktopChrome() }
            PreviewCard(title: "登录页 / 锁屏实际效果", tint: .purple, model: model, item: model.lockItem) { LockChrome() }
            HStack(spacing: 8) {
                Image(systemName: model.appliedLock != nil ? "checkmark.seal.fill" : "info.circle")
                    .font(.system(size: 12)).foregroundStyle(model.appliedLock != nil ? .green : .secondary)
                Text(noticeText).font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
        }
    }

    private var noticeText: String {
        if let n = model.notice { return n }
        if let d = model.appliedDesktop, let l = model.appliedLock { return "桌面「\(d)」· 登录页「\(l)」（均充满屏幕）" }
        return "右侧把图片分别指派给桌面与登录页；iPhone 联动在第二个标签页"
    }

    private var statusPill: some View {
        HStack(spacing: 6) {
            Circle().fill(model.overlayRunning ? Color.green : Color.orange).frame(width: 7, height: 7)
            Text(model.overlayRunning ? "覆盖服务运行中" : "点应用即启用").font(.system(size: 11, weight: .medium))
        }.padding(.horizontal, 10).padding(.vertical, 5).glassEffect(.regular, in: Capsule())
    }

    private var rightColumn: some View {
        VStack(spacing: 10) {
            Picker("", selection: $tab) {
                Text("壁纸").tag(0); Text("iPhone 联动").tag(1)
            }
            .pickerStyle(.segmented).labelsHidden()
            if tab == 0 { wallpaperTab } else { linkTab }
        }
    }

    // MARK: 壁纸页
    private var wallpaperTab: some View {
        VStack(spacing: 10) {
            GlassPanel {
                VStack(alignment: .leading, spacing: 6) {
                    assignLine(color: .blue, icon: "display", label: "桌面", name: model.desktopItem?.name)
                    assignLine(color: .purple, icon: "lock.fill", label: "登录页", name: model.lockItem?.name)
                }
            }
            GlassPanel(title: "壁纸库 · 点右侧图标指派") {
                ScrollView {
                    LazyVStack(spacing: 4) {
                        if model.items.isEmpty { emptyHint }
                        ForEach(model.items) { WallpaperRow(item: $0, model: model) }
                    }
                }.frame(height: 188)
                .onDrop(of: [.fileURL], isTargeted: nil) { providers in
                    let urls = providers.compactMap { p -> URL? in
                        guard p.canLoadObject(ofClass: URL.self) else { return nil }
                        var u: URL?; let sem = DispatchSemaphore(value: 0)
                        _ = p.loadObject(ofClass: URL.self) { url, _ in u = url; sem.signal() }; sem.wait(); return u
                    }
                    if !urls.isEmpty { model.importURLs(urls); return true }; return false
                }
                Button { model.importImage() } label: {
                    Label("从任意位置导入图片…", systemImage: "plus").font(.system(size: 12)).frame(maxWidth: .infinity)
                }.buttonStyle(.glass).controlSize(.small)
                Text("也可拖入；显示器=桌面，锁=登录页，悬停删除").font(.system(size: 10)).foregroundStyle(.secondary)
            }
            Button { model.applyAll() } label: {
                HStack(spacing: 8) {
                    if model.busy { ProgressView().controlSize(.small) } else { Image(systemName: "checkmark.circle.fill") }
                    Text(model.busy ? "正在应用…" : "应用").font(.system(size: 14, weight: .semibold))
                }.frame(maxWidth: .infinity).padding(.vertical, 4)
            }.buttonStyle(.glassProminent).controlSize(.large)
            .disabled(model.busy || model.desktopItem == nil || model.lockItem == nil)
            GlassPanel(title: "登录页常亮") {
                Toggle(isOn: Binding(get: { model.keepAwake }, set: { model.setKeepAwake($0) })) {
                    Text("锁屏/登录页不自动黑屏").font(.system(size: 12.5, weight: .medium))
                }
            }
            Spacer(minLength: 0)
            Button(role: .destructive) { model.restoreDefault() } label: {
                Label("恢复一致（登录页跟随桌面）", systemImage: "arrow.uturn.backward").font(.system(size: 11)).lineLimit(1).frame(maxWidth: .infinity)
            }.buttonStyle(.glass)
        }
    }

    private var emptyHint: some View {
        VStack(spacing: 6) {
            Image(systemName: "photo.on.rectangle.angled").font(.system(size: 22)).foregroundStyle(.secondary)
            Text("壁纸库还是空的").font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
            Text("点下方按钮，或直接把图片拖进来").font(.system(size: 10.5)).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity).padding(.vertical, 24)
    }

    private func assignLine(color: Color, icon: String, label: String, name: String?) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon).font(.system(size: 11)).foregroundStyle(color).frame(width: 16)
            Text(label).font(.system(size: 11.5)).foregroundStyle(.secondary)
            Spacer(minLength: 0)
            Text(name ?? "未选择").font(.system(size: 12, weight: .medium)).lineLimit(1)
        }
    }

    // MARK: iPhone 联动页
    private var linkTab: some View {
        ScrollView {
            VStack(spacing: 10) {
                Button { model.lockNow() } label: {
                    Label("立即锁屏", systemImage: "lock.fill").font(.system(size: 14, weight: .semibold))
                        .frame(maxWidth: .infinity).padding(.vertical, 6)
                }.buttonStyle(.glassProminent).controlSize(.large)

                remotePanel
                proximityPanel
                passwordPanel
                Spacer(minLength: 0)
            }
        }
    }

    private var remotePanel: some View {
        GlassPanel(title: "局域网遥控（同一 Wi-Fi）") {
            VStack(alignment: .leading, spacing: 8) {
                Toggle(isOn: Binding(get: { model.remoteEnabled }, set: { model.toggleRemote($0) })) {
                    Text("允许 iPhone 通过 Wi-Fi 连接").font(.system(size: 12.5, weight: .medium))
                }
                HStack(spacing: 8) {
                    Text("配对码").font(.system(size: 11.5)).foregroundStyle(.secondary)
                    Spacer()
                    Text(model.pairCode).font(.system(size: 18, weight: .bold, design: .monospaced)).tracking(3)
                    Button { model.resetPairCode() } label: { Image(systemName: "arrow.clockwise") }.buttonStyle(.glass).controlSize(.small)
                }
                if !model.ipAddresses.isEmpty {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(model.ipAddresses, id: \.self) { ip in
                            Text(ip).font(.system(size: 10.5, design: .monospaced)).foregroundStyle(.secondary)
                        }
                    }
                }
                Text("iPhone 端 Halo 会自动发现本机；发现不了就手动输入上面的 IP，并输入配对码。").font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var proximityPanel: some View {
        GlassPanel(title: "蓝牙靠近解锁（融合 BLEUnlock）") {
            VStack(alignment: .leading, spacing: 8) {
                Toggle(isOn: Binding(get: { model.prox.enabled }, set: { v in model.setProx { $0.enabled = v } })) {
                    Text("启用靠近自动解锁 / 远离自动锁屏").font(.system(size: 12.5, weight: .medium))
                }
                HStack(spacing: 8) {
                    Circle().fill(bleColor).frame(width: 8, height: 8)
                    Text(bleText).font(.system(size: 11)).foregroundStyle(.secondary)
                    Spacer()
                    if model.ble.connected { Text("\(model.ble.rssi) dBm").font(.system(size: 11, design: .monospaced)) }
                }
                Toggle(isOn: Binding(get: { model.prox.autoLock }, set: { v in model.setProx { $0.autoLock = v } })) {
                    Text("远离自动锁屏").font(.system(size: 11.5))
                }
                Toggle(isOn: Binding(get: { model.prox.autoUnlock }, set: { v in model.setProx { $0.autoUnlock = v } })) {
                    Text("靠近自动输入密码解锁").font(.system(size: 11.5))
                }
                thresholdRow(title: "远离阈值", value: model.prox.awayRSSI, range: -90...(-60)) { v in
                    model.setProx { $0.awayRSSI = v }
                }
                thresholdRow(title: "靠近阈值", value: model.prox.nearRSSI, range: -75...(-35)) { v in
                    model.setProx { $0.nearRSSI = v }
                }
                Button { model.startPairing() } label: {
                    Label("绑定我的 iPhone", systemImage: "antenna.radiowaves.left.and.right").font(.system(size: 11.5)).frame(maxWidth: .infinity)
                }.buttonStyle(.glass).controlSize(.regular)
                if !model.pairCandidates.isEmpty {
                    ForEach(model.pairCandidates) { d in
                        Button { model.pairDevice(d) } label: {
                            HStack { Text(d.name).font(.system(size: 11.5)); Spacer(); Text("\(d.rssi)dBm").font(.system(size: 10)).foregroundStyle(.secondary) }
                                .padding(.horizontal, 8).padding(.vertical, 6)
                                .background(RoundedRectangle(cornerRadius: 8).fill(.white.opacity(0.08)))
                        }.buttonStyle(.plain)
                    }
                }
                if !model.prox.peripheralName.isEmpty {
                    Text("已绑定：\(model.prox.peripheralName)").font(.system(size: 10)).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func thresholdRow(title: String, value: Int, range: ClosedRange<Int>, onChange: @escaping (Int) -> Void) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack { Text(title).font(.system(size: 10.5)).foregroundStyle(.secondary); Spacer(); Text("\(value) dBm").font(.system(size: 10.5, design: .monospaced)) }
            Slider(value: Binding(get: { Double(value) }, set: { onChange(Int($0)) }),
                   in: Double(range.lowerBound)...Double(range.upperBound), step: 1)
        }
    }

    private var bleColor: Color {
        if !model.prox.enabled { return .secondary }
        switch model.ble.zone { case "near": return .green; case "far": return .orange; default: return .yellow }
    }
    private var bleText: String {
        if !model.prox.enabled { return "未启用" }
        if model.ble.connected { return model.ble.zone == "near" ? "已连接 · 在附近" : "已连接 · 已远离" }
        if model.ble.powered { return "正在搜索 iPhone…" }
        return "蓝牙未开启"
    }

    private var passwordPanel: some View {
        GlassPanel(title: "自动解锁密码（仅存本机钥匙串）") {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Group {
                        if model.showPassword { TextField("登录密码", text: $model.passwordField) }
                        else { SecureField("登录密码", text: $model.passwordField) }
                    }.textFieldStyle(.roundedBorder).font(.system(size: 12))
                    Button { model.showPassword.toggle() } label: { Image(systemName: model.showPassword ? "eye.slash" : "eye") }.buttonStyle(.glass)
                }
                HStack(spacing: 8) {
                    Button { model.savePassword() } label: { Text(model.hasPassword ? "更新密码" : "保存密码").font(.system(size: 11.5)).frame(maxWidth: .infinity) }.buttonStyle(.glass)
                    if model.hasPassword {
                        Button { model.passwordField = ""; model.savePassword() } label: { Text("清除").font(.system(size: 11.5)) }.buttonStyle(.glass)
                    }
                }
                Label(model.hasPassword ? "已保存，靠近时自动输入" : "未保存则无法自动解锁", systemImage: model.hasPassword ? "checkmark.shield.fill" : "exclamationmark.shield")
                    .font(.system(size: 10)).foregroundStyle(model.hasPassword ? Color.secondary : Color.orange)
            }
        }
    }
}

// MARK: - 壁纸行

struct WallpaperRow: View {
    let item: WPItem
    @ObservedObject var model: AppModel
    @State private var hover = false
    private var isDesktop: Bool { model.desktopID == item.id }
    private var isLock: Bool { model.lockID == item.id }

    var body: some View {
        HStack(spacing: 8) {
            AsyncThumb(item: item, edge: 120, model: model).frame(width: 56, height: 36)
                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(.white.opacity(0.12), lineWidth: 0.5))
            VStack(alignment: .leading, spacing: 2) {
                Text(item.name).font(.system(size: 12.5, weight: .medium)).lineLimit(1)
                Text("已导入").font(.system(size: 9.5)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            assignButton(icon: "display", active: isDesktop, color: .blue) { model.desktopID = item.id }
            assignButton(icon: "lock.fill", active: isLock, color: .purple) { model.lockID = item.id }
            if hover {
                Button(role: .destructive) { model.confirmDelete(item) } label: {
                    Image(systemName: "trash").font(.system(size: 11)).foregroundStyle(.secondary).frame(width: 22, height: 22)
                }.buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 7).padding(.vertical, 5)
        .background { if isDesktop || isLock { RoundedRectangle(cornerRadius: 10).fill(.white.opacity(0.10)) } }
        .contentShape(Rectangle()).onHover { hover = $0 }
    }
    private func assignButton(icon: String, active: Bool, color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 11, weight: .semibold)).foregroundStyle(active ? .white : .secondary)
                .frame(width: 26, height: 22).background { if active { RoundedRectangle(cornerRadius: 7).fill(color) } }
        }.buttonStyle(.plain)
    }
}
