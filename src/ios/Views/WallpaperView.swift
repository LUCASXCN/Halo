//
//  WallpaperView.swift — 远程选择 Mac 桌面 / 登录页壁纸，支持相册上传
//

import SwiftUI
import PhotosUI

struct WallpaperView: View {
    @ObservedObject var model: AppModel
    @State private var assignSlot: SlotKind?
    @State private var pickerItem: PhotosPickerItem?
    @State private var columns = [GridItem(.adaptive(minimum: 104), spacing: 12)]

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                slots
                uploadBar
                grid
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

    private var grid: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionTitle(icon: "photo.on.rectangle.angled", text: "Mac 壁纸库 · 点图下方按钮指派")
            LazyVGrid(columns: columns, spacing: 12) {
                ForEach(model.wallpapers) { wp in
                    WallpaperCell(model: model, wp: wp)
                }
            }
        }
        .padding(18)
        .haloGlass()
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

private struct WallpaperCell: View {
    @ObservedObject var model: AppModel
    let wp: WallpaperInfo
    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                RoundedRectangle(cornerRadius: 14).fill(.thinMaterial).frame(height: 104)
                if let img = model.thumbnail(wp.id) {
                    Image(uiImage: img).resizable().scaledToFill()
                        .frame(height: 104).clipShape(RoundedRectangle(cornerRadius: 14))
                } else { ProgressView() }
            }
            Text(wp.name).font(.caption2).lineLimit(1)
            HStack(spacing: 6) {
                Button {
                    Task { await model.assign(.desktop, id: wp.id) }
                } label: { Image(systemName: model.desktopID == wp.id ? "desktopcomputer.circle.fill" : "desktopcomputer") }
                    .buttonStyle(.borderless)
                Button {
                    Task { await model.assign(.lock, id: wp.id) }
                } label: { Image(systemName: model.lockID == wp.id ? "lock.circle.fill" : "lock") }
                    .buttonStyle(.borderless)
            }
            .font(.body)
        }
    }
}
