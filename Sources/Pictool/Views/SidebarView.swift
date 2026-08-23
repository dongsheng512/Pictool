import SwiftUI

/// 左侧边栏:上半区项目文件夹树,下半区当前文件夹的缩略图网格
struct SidebarView: View {

    @Environment(FolderStore.self) private var store
    @State private var expandedIDs: Set<FolderNode.ID> = []
    /// 缩略图区是否向上扩展(压缩文件夹树高度);再点一次复原
    @State private var thumbnailsExpanded = false

    var body: some View {
        VStack(spacing: 0) {
            folderTree
            Divider()
            ThumbnailGridView(expanded: $thumbnailsExpanded)
        }
        .animation(.easeInOut(duration: 0.22), value: thumbnailsExpanded)
        .navigationSplitViewColumnWidth(min: 200, ideal: 260, max: 440)
    }

    private var folderTree: some View {
        Group {
            if store.roots.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "folder.badge.plus")
                        .font(.system(size: 28))
                        .foregroundStyle(.secondary)
                    Text("尚未打开文件夹")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Button("打开文件夹…") { store.openFolderPanel() }
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
            }
        }
        .frame(minHeight: 110, maxHeight: thumbnailsExpanded ? 110 : 340)
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
