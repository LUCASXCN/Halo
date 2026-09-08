//
//  WallpaperView.swift — 远程选择 Mac 桌面 / 登录页壁纸，支持相册上传
//  壁纸库：左右滑动分页查看，底部大按钮一键指派
//

import SwiftUI
import PhotosUI

struct WallpaperView: View {
    @ObservedObject var model: AppModel
    @State private var assignSlot: SlotKind?
    @State private var pickerItem: PhotosPickerItem?
    @State private var currentPage = 0

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                slots
                uploadBar
                wallpaperLibrary
                applyBar
            }
            .padding(20)
        }
        .background(HaloBackground())
        .task { try? await model.refresh() }
        .onChange(of: pickerItem) { _, item in
            guard let item, let slot = assignSlot else { return }
            Task {
                if let data = try? await item.loadTransferable(type: Data.self),
                   let img = UIImage(data: data) {
                    await model.uploadAndAssign(image: img, assign: slot)
                }
                pickerItem = nil
            }
        }
    }

    // 当前双槽
    private var slots: some View {
        HStack(spacing: 12) {
            slotCard(title: "桌面壁纸", system: "desktopcomputer", id: model.desktopID, slot: .desktop)
            slotCard(title: "登录页壁纸", system: "lock", id: model.lockID, slot: .lock)
        }
    }

    private func slotCard(title: String, system: String, id: String?, slot: SlotKind) -> some View {
        VStack(spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(.thinMaterial).frame(height: 96)
                if let id, let img = model.thumbnail(id) {
                    Image(uiImage: img).resizable().scaledToFill()
                        .frame(height: 96).clipShape(RoundedRectangle(cornerRadius: 16))
                } else {
                    Image(systemName: system).font(.title2).foregroundStyle(.secondary)
                }
            }
            Text(title).font(.caption.weight(.semibold))
            Text(displayName(id)).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
        }
        .frame(maxWidth: .infinity)
        .padding(12)
        .haloGlass()
    }

    private var uploadBar: some View {
        HStack(spacing: 10) {
            PhotosPicker(selection: $pickerItem, matching: .images) {
                Label("上传到桌面", systemImage: "square.and.arrow.up")
                    .frame(maxWidth: .infinity).padding(.vertical, 12)
            }
            .onTapGesture { assignSlot = .desktop }
            .buttonStyle(.bordered).tint(.blue)
            .clipShape(RoundedRectangle(cornerRadius: 14))

            PhotosPicker(selection: $pickerItem, matching: .images) {
                Label("上传到登录页", systemImage: "square.and.arrow.up")
                    .frame(maxWidth: .infinity).padding(.vertical, 12)
            }
            .onTapGesture { assignSlot = .lock }
            .buttonStyle(.bordered).tint(.purple)
            .clipShape(RoundedRectangle(cornerRadius: 14))
        }
    }

    // MARK: - 壁纸库：左右滑动分页 + 底部大按钮

    private var wallpaperLibrary: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionTitle(icon: "photo.on.rectangle.angled", text: "Mac 壁纸库 · 左右滑动查看")

            if model.wallpapers.isEmpty {
                Text("壁纸库为空，先从上方上传图片")
                    .font(.subheadline).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity).padding(.vertical, 40)
            } else {
                // 横向分页滑动
                TabView(selection: $currentPage) {
                    ForEach(Array(model.wallpapers.enumerated()), id: \.element.id) { idx, wp in
                        WallpaperPage(model: model, wp: wp)
                            .tag(idx)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
                .frame(height: 300)
                .clipShape(RoundedRectangle(cornerRadius: 20))

                // 页码指示
                HStack(spacing: 6) {
                    ForEach(0..<model.wallpapers.count, id: \.self) { i in
                        Circle()
                            .fill(i == currentPage ? Color.blue : Color.secondary.opacity(0.3))
                            .frame(width: 7, height: 7)
                    }
                }
                .frame(maxWidth: .infinity)

                // 当前壁纸名
                if let wp = currentWallpaper {
                    Text(wp.name).font(.subheadline.weight(.medium)).frame(maxWidth: .infinity)
                }

                // 底部两个大按钮
                HStack(spacing: 12) {
                    assignButton(title: "桌面壁纸", systemImage: "desktopcomputer",
                                 tint: .blue, slot: .desktop, isActive: model.desktopID == currentWallpaper?.id)
                    assignButton(title: "登录页壁纸", systemImage: "lock",
                                 tint: .purple, slot: .lock, isActive: model.lockID == currentWallpaper?.id)
                }
            }
        }
        .padding(18)
        .haloGlass()
    }

    private var currentWallpaper: WallpaperInfo? {
        guard currentPage < model.wallpapers.count else { return nil }
        return model.wallpapers[currentPage]
    }

    private func assignButton(title: String, systemImage: String, tint: Color,
                              slot: SlotKind, isActive: Bool) -> some View {
        Button {
            guard let wp = currentWallpaper else { return }
            Task { await model.assign(slot, id: wp.id) }
        } label: {
            VStack(spacing: 4) {
                Image(systemName: isActive ? "\(systemImage).circle.fill" : systemImage)
                    .font(.title2)
                Text(title).font(.subheadline.weight(.semibold))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
        }
        .buttonStyle(.borderedProminent)
        .tint(isActive ? tint : tint.opacity(0.7))
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .shadow(color: tint.opacity(0.2), radius: 8, y: 3)
    }

    private var applyBar: some View {
        GlassPrimaryButton(title: model.busy ? "处理中…" : "应用到 Mac",
                           systemImage: "checkmark.circle.fill") {
            Task { await model.apply() }
        }
        .disabled(model.busy)
        .opacity(model.busy ? 0.6 : 1)
    }

    private func displayName(_ id: String?) -> String {
        guard let id else { return "未选择" }
        return model.wallpapers.first(where: { $0.id == id })?.name ?? id
    }
}

// 单页壁纸大图
private struct WallpaperPage: View {
    @ObservedObject var model: AppModel
    let wp: WallpaperInfo
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 20).fill(.thinMaterial)
            if let img = model.thumbnail(wp.id) {
                Image(uiImage: img).resizable().scaledToFill()
            } else {
                ProgressView()
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 20))
        .padding(.horizontal, 4)
    }
}
