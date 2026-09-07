//
//  HaloRemoteApp.swift — iPhone App 入口（iOS 27 · SwiftUI · Liquid Glass）
//

import SwiftUI

@main
struct HaloRemoteApp: App {
    var body: some Scene {
        WindowGroup {
            RootView()
        }
    }
}

struct RootView: View {
    @ObservedObject var model = AppModel.shared
    var body: some View {
        Group {
            if model.connected {
                MainTabs()
            } else {
                ConnectView(model: model)
            }
        }
        .overlay(alignment: .bottom) {
            if let t = model.toast {
                ToastView(text: t).transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
    }
}

struct MainTabs: View {
    @ObservedObject var model = AppModel.shared
    var body: some View {
        TabView {
            RemoteView(model: model)
                .tabItem { Label("遥控", systemImage: "lock.fill") }
            WallpaperView(model: model)
                .tabItem { Label("壁纸", systemImage: "photo.fill") }
            ProximityView(model: model)
                .tabItem { Label("靠近", systemImage: "wave.3.right.circle.fill") }
        }
        .safeAreaInset(edge: .top) { topBar }
        .tint(.blue)
    }

    private var topBar: some View {
        HStack(spacing: 8) {
            StatusDot(ok: true)
            Text(model.macName).font(.subheadline.weight(.semibold)).lineLimit(1)
            Spacer()
            Button {
                model.disconnect()
            } label: {
                Label("断开", systemImage: "xmark.circle").labelStyle(.iconOnly)
            }
            .buttonStyle(.plain).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(.ultraThinMaterial)
    }
}
