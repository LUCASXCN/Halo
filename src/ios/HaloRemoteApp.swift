//
//  HaloRemoteApp.swift — iPhone App 入口（iOS 27 · SwiftUI · Liquid Glass · 深色模式）
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
        VStack(spacing: 0) {
            topBar
            tabs
        }
        .tint(.blue)
    }

    // iOS 26+ 原生悬浮 Liquid Glass 胶囊底栏；向下滚动自动收缩为小胶囊
    @ViewBuilder
    private var tabs: some View {
        if #available(iOS 26.0, *) {
            TabView {
                tabContents
            }
            .tabBarMinimizeBehavior(.onScrollDown)
        } else {
            TabView { tabContents }
        }
    }

    @ViewBuilder
    private var tabContents: some View {
        RemoteView(model: model)
            .tabItem { Label("遥控", systemImage: "lock.fill") }
        WallpaperView(model: model)
            .tabItem { Label("壁纸", systemImage: "photo.fill") }
        ProximityView(model: model)
            .tabItem { Label("靠近", systemImage: "wave.3.right.circle.fill") }
    }

    // 玻璃顶栏（固定在顶部，不悬浮遮挡内容）
    private var topBar: some View {
        HStack(spacing: 8) {
            StatusDot(ok: true)
            Text(model.macName).font(.subheadline.weight(.semibold)).lineLimit(1)
            Spacer()
            Button {
                model.disconnect()
            } label: {
                Label("断开", systemImage: "xmark.circle.fill").labelStyle(.iconOnly)
            }
            .buttonStyle(.plain).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .haloGlass(corner: 22)
        .padding(.horizontal, 14)
        .padding(.top, 8)
        .padding(.bottom, 4)
    }
}
