//
//  Components.swift — Liquid Glass 复用视觉组件（iOS 26/27，原生适配深色模式）
//

import SwiftUI

// MARK: - 液态玻璃容器（自动适配浅色/深色）

struct HaloGlassContainer<Content: View>: View {
    @Environment(\.colorScheme) private var scheme
    var corner: CGFloat = 26
    let content: Content

    var body: some View {
        if #available(iOS 26.0, *) {
            // 原生 Liquid Glass；深色下用极淡青色 tint 保持品牌冷调，浅色下用淡白
            content.glassEffect(
                .regular
                    .tint(scheme == .dark ? Color.cyan.opacity(0.14) : Color.white.opacity(0.12))
                    .interactive(),
                in: .rect(cornerRadius: corner, style: .continuous)
            )
        } else {
            content.background(
                RoundedRectangle(cornerRadius: corner, style: .continuous)
                    .fill(.ultraThinMaterial)
                    .overlay(
                        RoundedRectangle(cornerRadius: corner, style: .continuous)
                            .stroke(Color.primary.opacity(0.06), lineWidth: 1)
                    )
            )
        }
    }
}

extension View {
    /// 液态玻璃容器（浅色/深色自适应）
    func haloGlass(corner: CGFloat = 26) -> some View {
        HaloGlassContainer(corner: corner, content: self)
    }
}

// MARK: - 玻璃主按钮（胶囊）

struct GlassPrimaryButton: View {
    let title: String
    var systemImage: String?
    var tint: Color = .blue
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                if let systemImage { Image(systemName: systemImage) }
                Text(title).fontWeight(.semibold)
            }
            .font(.body)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
        }
        .buttonStyle(.borderedProminent)
        .tint(tint)
        .clipShape(Capsule())
        .shadow(color: tint.opacity(0.25), radius: 10, y: 4)
    }
}

// MARK: - 区块标题

struct SectionTitle: View {
    let icon: String
    let text: String
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon).font(.subheadline)
            Text(text).font(.subheadline.weight(.semibold))
        }
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - 状态点

struct StatusDot: View {
    let ok: Bool
    var body: some View {
        Circle()
            .fill(ok ? Color.green : Color.gray)
            .frame(width: 9, height: 9)
            .overlay(Circle().stroke(.white.opacity(0.6), lineWidth: 1))
    }
}

// MARK: - 全局背景（浅色=天蓝渐变；深色=深蓝夜幕渐变，同色系暗化，跟随系统）

struct HaloBackground: View {
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        LinearGradient(colors: scheme == .dark ? dark : light,
                       startPoint: .topLeading, endPoint: .bottomTrailing)
            .ignoresSafeArea()
    }
    private let light: [Color] = [
        Color(red: 0.53, green: 0.83, blue: 0.98),
        Color(red: 0.78, green: 0.92, blue: 1.0),
        Color(red: 0.93, green: 0.98, blue: 1.0)
    ]
    private let dark: [Color] = [
        Color(red: 0.055, green: 0.11, blue: 0.20),
        Color(red: 0.035, green: 0.07, blue: 0.14),
        Color(red: 0.015, green: 0.035, blue: 0.085)
    ]
}

// MARK: - Toast（悬浮玻璃胶囊）

struct ToastView: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.subheadline.weight(.medium))
            .padding(.horizontal, 18).padding(.vertical, 12)
            .haloGlass(corner: 22)
            .padding(.bottom, 8)
    }
}
