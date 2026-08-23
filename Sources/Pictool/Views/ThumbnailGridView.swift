import SwiftUI

/// 边栏下半区:当前文件夹的缩略图网格(异步加载、当前项高亮、切换跟随滚动)
struct ThumbnailGridView: View {

    @Environment(FolderStore.self) private var store
    /// 是否处于向上扩展态(由 SidebarView 持有,联动压缩文件夹树)
    @Binding var expanded: Bool

    private let columns = [GridItem(.adaptive(minimum: 84, maximum: 140), spacing: 8)]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "photo.grid")
                    .foregroundStyle(.secondary)
                Text("缩略图")
                    .font(.callout.weight(.semibold))
                Spacer()
                Button {
                    expanded.toggle()
                } label: {
                    Image(systemName: expanded ? "chevron.down" : "chevron.up")
                }
                .buttonStyle(FlatPillButtonStyle())
                .help(expanded ? "复原缩略图区域" : "扩大缩略图区域")
                Spacer()
                Text("\(store.images.count)")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            if store.images.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "photo.stack")
                        .font(.system(size: 24))
                        .foregroundStyle(.secondary)
                    Text(store.selectedFolder == nil ? "选择一个文件夹" : "此文件夹没有图片")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVGrid(columns: columns, spacing: 10) {
                            ForEach(store.images) { file in
                                ThumbCell(file: file, isCurrent: file.id == store.selectedImageID)
                                    .id(file.id)
                                    .onTapGesture { store.selectImage(file.id) }
                                    .contextMenu {
                                        Button {
                                            store.copyImageToPasteboard(file.id)
                                        } label: {
                                            Label("复制图片", systemImage: "doc.on.doc")
                                        }
                                        Button {
                                            store.hideImage(file.id)
                                        } label: {
                                            Label("隐藏", systemImage: "eye.slash")
                                        }
                                        Divider()
                                        Button(role: .destructive) {
                                            store.deleteImage(file.id)
                                        } label: {
                                            Label("删除", systemImage: "trash")
                                        }
                                    }
                            }
                        }
                        .padding(12)
                    }
                    .onChange(of: store.selectedImageID) { _, id in
                        guard let id else { return }
                        withAnimation(.easeInOut(duration: 0.18)) {
                            proxy.scrollTo(id, anchor: .center)
                        }
                    }
                }
            }
        }
        .frame(maxHeight: .infinity)
    }
}

/// 扁平小胶囊按钮:固定 28×16(与 callout 文字行高一致),半透明底 + 细描边
struct FlatPillButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(.primary.opacity(0.7))
            .frame(width: 42, height: 16)
            .background(Capsule().fill(Color.primary.opacity(configuration.isPressed ? 0.16 : 0.08)))
            .overlay(Capsule().strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5))
            .contentShape(Capsule())
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .animation(.easeInOut(duration: 0.12), value: configuration.isPressed)
    }
}

struct ThumbCell: View {

    let file: ImageFile
    let isCurrent: Bool
    @State private var thumb: NSImage?

    var body: some View {
        VStack(spacing: 4) {
            Group {
                if let thumb {
                    Image(nsImage: thumb)
                        .resizable()
                        .aspectRatio(contentMode: .fit)   // 完整显示整张图,不裁切
                        .padding(2)
                } else {
                    ZStack {
                        Rectangle().fill(.quaternary)
                        ProgressView().controlSize(.small)
                    }
                }
            }
            .frame(height: 76)
            .frame(maxWidth: .infinity)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.06)))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(isCurrent ? Color.accentColor : .clear, lineWidth: 2.5)
            )

            Text(file.name)
                .font(.system(size: 10))
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(isCurrent ? .primary : .secondary)
        }
        .padding(5)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isCurrent ? Color.accentColor.opacity(0.15) : Color.clear)
        )
        .contentShape(Rectangle())
        .task(id: file.id) {
            if thumb == nil {
                thumb = await ThumbnailProvider.shared.asyncThumbnail(for: file.url, maxPixel: 180)
            }
        }
    }
}
