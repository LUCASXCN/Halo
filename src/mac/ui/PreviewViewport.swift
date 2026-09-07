//
//  PreviewViewport.swift — 双观察窗：桌面实际效果 + 登录页实际效果（所见即所得）
//
import SwiftUI
import AppKit

/// 异步解码缩略图（进入 NSCache，切换零卡顿），严格填满给定尺寸
struct AsyncThumb: View {
    let item: WPItem?
    let edge: CGFloat
    @ObservedObject var model: AppModel
    @State private var img: NSImage?
    @State private var token = ""

    var body: some View {
        ZStack {
            if let img {
                Image(nsImage: img).resizable().scaledToFill()
            } else {
                Rectangle().fill(Color(white: 0.12))
                    .overlay(Image(systemName: "photo").font(.title3).foregroundStyle(.white.opacity(0.35)))
            }
        }
        .onAppear(perform: load)
        .onChange(of: item?.id) { _, _ in img = nil; load() }
    }

    private func load() {
        guard let item else { img = nil; return }
        token = item.id
        let url = item.url, e = edge
        if let hit = model.thumbnail(item, edge: e) { img = hit; return }
        DispatchQueue.global(qos: .userInitiated).async {
            let decoded = ImageEngine.thumbnail(at: url, maxEdge: e)
            DispatchQueue.main.async { if self.token == item.id { self.img = decoded } }
        }
    }
}

/// 单个观察窗：16:10，角标 + 自定义叠加层
struct PreviewCard<Overlay: View>: View {
    let title: String
    let tint: Color
    @ObservedObject var model: AppModel
    let item: WPItem?
    @ViewBuilder var overlay: () -> Overlay

    var body: some View {
        GeometryReader { geo in
            ZStack {
                AsyncThumb(item: item, edge: 900, model: model)
                    .frame(width: geo.size.width, height: geo.size.height)
                overlay()
                LinearGradient(colors: [.black.opacity(0.16), .clear, .clear, .black.opacity(0.14)],
                               startPoint: .top, endPoint: .bottom).allowsHitTesting(false)
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(.white.opacity(0.14), lineWidth: 1))
            .overlay(alignment: .topLeading) {
                HStack(spacing: 6) {
                    Circle().fill(tint).frame(width: 7, height: 7)
                    Text(title).font(.system(size: 11, weight: .medium))
                }
                .padding(.horizontal, 10).padding(.vertical, 5)
                .glassEffect(.regular, in: Capsule()).padding(10)
            }
        }
        .aspectRatio(16.0 / 10.0, contentMode: .fit)
    }
}

/// 桌面效果叠加：顶部菜单栏 + 底部 Dock 暗示
struct DesktopChrome: View {
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Finder  文件  编辑  显示").font(.system(size: 9, weight: .medium))
                Spacer()
                Text("21:07").font(.system(size: 9, weight: .medium))
            }
            .foregroundStyle(.white.opacity(0.92))
            .padding(.horizontal, 12).padding(.vertical, 5)
            .background(.black.opacity(0.18))
            Spacer()
            HStack(spacing: 6) {
                ForEach(0..<9, id: \.self) { _ in
                    RoundedRectangle(cornerRadius: 4).fill(.white.opacity(0.22)).frame(width: 22, height: 22)
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .glassEffect(.regular, in: Capsule())
            .padding(.bottom, 8)
        }
    }
}

/// 登录页效果叠加：时钟 + 头像密码框
struct LockChrome: View {
    private static let fmt: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale(identifier: "zh_CN"); f.dateFormat = "M月d日 EEEE"; return f
    }()
    var body: some View {
        VStack(spacing: 0) {
            TimelineView(.periodic(from: .now, by: 1)) { ctx in
                VStack(spacing: 2) {
                    Text(Self.fmt.string(from: ctx.date)).font(.system(size: 12, weight: .medium))
                    Text(ctx.date, format: .dateTime.hour().minute())
                        .font(.system(size: 46, weight: .thin, design: .rounded))
                }
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.25), radius: 8, y: 2)
                .padding(.top, 16)
            }
            Spacer()
            VStack(spacing: 8) {
                Circle().fill(.white.opacity(0.85)).frame(width: 38, height: 38)
                    .overlay(Image(systemName: "person.fill").font(.system(size: 16)).foregroundStyle(.gray))
                Capsule().fill(.white.opacity(0.28)).frame(width: 130, height: 22)
                    .overlay(Text("输入密码").font(.system(size: 10)).foregroundStyle(.white.opacity(0.85)))
            }
            .padding(.bottom, 14)
        }
    }
}
