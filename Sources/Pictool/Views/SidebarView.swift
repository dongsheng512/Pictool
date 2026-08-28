import SwiftUI
import AppKit

/// 左侧边栏:上半区项目文件夹树,下半区当前文件夹的缩略图网格
struct SidebarView: View {

    @Environment(FolderStore.self) private var store
    @Environment(\.colorScheme) private var colorScheme
    @State private var expandedIDs: Set<FolderNode.ID> = []
    /// 缩略图区是否向上扩展(压缩文件夹树高度);再点一次复原
    @State private var thumbnailsExpanded = false

    var body: some View {
        VStack(spacing: 0) {
            folderTree
            if store.isSingleImageMode, store.pendingOtherCount > 0 {
                singleImagePrompt
            }
            if !store.roots.isEmpty {
                ThumbnailGridView(expanded: $thumbnailsExpanded)
            }
        }
        .animation(.easeInOut(duration: 0.22), value: thumbnailsExpanded)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            ZStack {
                SidebarMaterial()
                ChromeTheme.sidebarWash(for: colorScheme)
            }
        }
    }

    private var folderTree: some View {
        Group {
            if store.roots.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "folder")
                        .font(.system(size: 28))
                        .foregroundStyle(.tertiary)
                    Text("尚未打开文件夹")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(selection: selectionBinding) {
                    ForEach(store.roots) { node in
                        FolderTreeRow(node: node, store: store, expandedIDs: $expandedIDs)
                            .tag(node.id)
                    }
                }
                .listStyle(.sidebar)
                .scrollContentBackground(.hidden)
            }
        }
        .frame(
            minHeight: 110,
            maxHeight: store.roots.isEmpty ? .infinity : (thumbnailsExpanded ? 110 : 340)
        )
    }

    private var selectionBinding: Binding<FolderNode.ID?> {
        Binding(
            get: { store.selectedFolderID },
            set: { newValue in
                guard let id = newValue, let node = store.node(id: id) else { return }
                store.selectFolder(node)
            }
        )
    }

    private var singleImagePrompt: some View {
        VStack(spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "photo.on.rectangle.angled")
                    .foregroundStyle(.secondary)
                    .font(.system(size: 11))
                Text("同目录还有 \(store.pendingOtherCount) 张")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
            }
            Button {
                store.loadAllFromCurrentFolder()
            } label: {
                Text("加载同目录所有图片")
                    .font(.caption.weight(.medium))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .tint(Color.accentColor)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.primary.opacity(0.06))
        )
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
    }
}

/// Finder 同款侧栏材质(顶栏左侧与侧栏共用)
struct SidebarMaterial: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .sidebar
        view.blendingMode = .behindWindow
        view.state = .followsWindowActiveState
        // 保持跟随系统外观，浅色下更通透
        return view
    }
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

enum ChromeTheme {
    /// 主区背景(欢迎页 / 画布浅色 #FAFAFB)
    static let mainAreaFill = Color(red: 0.980, green: 0.980, blue: 0.984)

    static func sidebarWash(for scheme: ColorScheme) -> Color {
        scheme == .dark ? Color.clear : Color.white.opacity(0.10)
    }

    static func fill(_ canvas: CanvasBackground) -> Color {
        canvas.isDark ? Color(white: 0.10) : mainAreaFill
    }

    static func colorScheme(for canvas: CanvasBackground) -> ColorScheme {
        canvas.isDark ? .dark : .light
    }
}

/// 主区顶栏/底栏/欢迎页,跟画布纯色
struct MainChromeBackground: View {
    var canvas: CanvasBackground

    var body: some View {
        ChromeTheme.fill(canvas)
    }
}

/// 侧栏顶段(红绿灯列):与侧栏同材质,不跟主区顶栏
struct SidebarTopBackground: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack {
            SidebarMaterial()
            ChromeTheme.sidebarWash(for: colorScheme)
        }
    }
}

struct FolderTreeRow: View {

    let node: FolderNode
    let store: FolderStore
    @Binding var expandedIDs: Set<FolderNode.ID>

    var body: some View {
        DisclosureGroup(isExpanded: expansionBinding) {
            ForEach(node.children) { child in
                FolderTreeRow(node: child, store: store, expandedIDs: $expandedIDs)
                    .tag(child.id)
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: node.depth == 0 ? "folder.fill" : "folder")
                    .foregroundStyle(node.depth == 0 ? Color.accentColor : .secondary)
                Text(node.name)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .contextMenu {
                Button("刷新") {
                    store.selectFolder(node)
                }
                if node.depth == 0 {
                    Button("从侧栏移除", role: .destructive) {
                        store.removeRoot(id: node.id)
                    }
                }
            }
        }
    }

    private var expansionBinding: Binding<Bool> {
        Binding(
            get: { expandedIDs.contains(node.id) },
            set: { open in
                if open {
                    store.ensureChildren(of: node)
                    expandedIDs.insert(node.id)
                } else {
                    expandedIDs.remove(node.id)
                }
            }
        )
    }
}
