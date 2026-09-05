import SwiftUI
import AppKit

/// 左侧边栏:上半区项目文件夹树,下半区当前文件夹的缩略图网格
struct SidebarView: View {

    @Environment(FolderStore.self) private var store
    /// 侧栏明暗跟随画布背景偏好(而不是系统外观)
    @AppStorage(CanvasBackground.storageKey) private var canvasBackground = CanvasBackground.defaultValue
    private var sidebarScheme: ColorScheme { ChromeTheme.colorScheme(for: canvasBackground) }
    @State private var expandedIDs: Set<FolderNode.ID> = []
    /// 缩略图区是否向上扩展(压缩文件夹树高度);再点一次复原。
    /// 打开/切换文件夹后默认展开,手动复原后不再被打断(直到下次切文件夹)
    @State private var thumbnailsExpanded = true

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
        .onChange(of: store.selectedFolderID) { _, _ in
            thumbnailsExpanded = true
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            ZStack {
                SidebarMaterial(dark: canvasBackground.isDark)
                ChromeTheme.sidebarWash(for: sidebarScheme)
            }
        }
        // 侧栏内文字/选中态/控件颜色跟随画布背景明暗
        .environment(\.colorScheme, sidebarScheme)
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
    /// 跟随画布背景明暗:黑色画布时用深色磨砂(vibrantDark)
    var dark: Bool = false

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .sidebar
        view.blendingMode = .behindWindow
        view.state = .followsWindowActiveState
        applyAppearance(to: view)
        return view
    }
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        applyAppearance(to: nsView)
    }

    private func applyAppearance(to view: NSVisualEffectView) {
        // 磨砂材质的明暗由外观决定;画布选黑时强制深色外观,得到黑色磨砂
        view.appearance = NSAppearance(named: dark ? .vibrantDark : .aqua)
    }
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

    /// 编辑/浏览画布:比顶栏底栏略深,工作区才从界面里分出来。
    static func canvasFill(_ canvas: CanvasBackground) -> Color {
        canvas.isDark ? Color(white: 0.07) : Color(red: 0.945, green: 0.945, blue: 0.950)
    }

    /// 编辑工具条与顶栏同一底色,只靠 hairline 分开,避免两层色块。
    static func editBarFill(_ canvas: CanvasBackground) -> Color {
        fill(canvas)
    }

    static func colorScheme(for canvas: CanvasBackground) -> ColorScheme {
        canvas.isDark ? .dark : .light
    }

    /// 顶栏与编辑条之间的淡实线(不透明,避免透出窗口)
    static func hairline(_ canvas: CanvasBackground) -> Color {
        canvas.isDark ? Color.white.opacity(0.10) : Color.black.opacity(0.06)
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
    @AppStorage(CanvasBackground.storageKey) private var canvasBackground = CanvasBackground.defaultValue

    var body: some View {
        ZStack {
            SidebarMaterial(dark: canvasBackground.isDark)
            ChromeTheme.sidebarWash(for: ChromeTheme.colorScheme(for: canvasBackground))
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
