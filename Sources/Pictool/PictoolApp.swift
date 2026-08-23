import SwiftUI

@main
struct PictoolApp: App {

    @State private var store = FolderStore()

    var body: some Scene {
        Window("PureView", id: "main") {
            MainContentView()
                .environment(store)
        }
        .defaultSize(width: 1200, height: 760)
        // 紧凑工具栏,降低顶部高度
        .windowToolbarStyle(.unifiedCompact)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("打开文件夹…") { store.openFolderPanel() }
                    .keyboardShortcut("o", modifiers: .command)
                Button("刷新") { store.refreshCurrentFolder() }
                    .keyboardShortcut("r", modifiers: .command)
                    .disabled(store.selectedFolder == nil)
            }
            CommandGroup(replacing: .printItem) {
                Button("打印…") { store.requestPrint() }
                    .keyboardShortcut("p", modifiers: .command)
                    .disabled(store.currentImage == nil)
            }
            CommandMenu("图片") {
                Button("上一张") { store.step(-1) }
                    .keyboardShortcut(.leftArrow, modifiers: [])
                    .disabled(store.images.isEmpty)
                Button("下一张") { store.step(1) }
                    .keyboardShortcut(.rightArrow, modifiers: [])
                    .disabled(store.images.isEmpty)
                Divider()
                Button("适配窗口") { store.requestZoom(.fit) }
                    .keyboardShortcut("0", modifiers: [])
                Button("实际大小") { store.requestZoom(.actualSize) }
                    .keyboardShortcut("1", modifiers: [])
                Button("放大") { store.requestZoom(.zoomIn) }
                    .keyboardShortcut("=", modifiers: .command)
                Button("缩小") { store.requestZoom(.zoomOut) }
                    .keyboardShortcut("-", modifiers: .command)
                Divider()
                Button("信息面板") { store.showInspector.toggle() }
                    .keyboardShortcut("i", modifiers: [])
                Button("裁切…") { store.requestCrop() }
                    .keyboardShortcut("c", modifiers: [])
                    .disabled(store.currentImage == nil)
                Divider()
                Button("顺时针旋转 90°") { store.requestRotate() }
                    .keyboardShortcut("r", modifiers: [.command, .option])
                    .disabled(store.currentImage == nil)
            }
        }
    }
}
