//
//  Components.swift — Liquid Glass 复用视觉组件
//

import SwiftUI

// MARK: - 玻璃卡片（iOS 26 Liquid Glass）

extension View {
    /// 液态玻璃容器
    @ViewBuilder
    func haloGlass(corner: CGFloat = 26, tint: Color = .white.opacity(0.12)) -> some View {
        if #available(iOS 26.0, *) {
            self.glassEffect(.regular.tint(tint).interactive(),
                             in: .rect(cornerRadius: corner, style: .continuous))
        } else {
            self.background(
                RoundedRectangle(cornerRadius: corner, style: .continuous)
                    .fill(.ultraThinMaterial)
            )
        }
    }
}

// MARK: - 玻璃大按钮

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
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
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

// MARK: - 顶部渐变背景（天蓝色，呼应下载页）

struct HaloBackground: View {
    var body: some View {
        LinearGradient(colors: [
            Color(red: 0.53, green: 0.83, blue: 0.98),
            Color(red: 0.78, green: 0.92, blue: 1.0),
            Color(red: 0.93, green: 0.98, blue: 1.0)
        ], startPoint: .topLeading, endPoint: .bottomTrailing)
        .ignoresSafeArea()
    }
}

// MARK: - Toast

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
