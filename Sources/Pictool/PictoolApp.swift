import SwiftUI
import AppKit
import UniformTypeIdentifiers

extension Notification.Name {
    static let openExternalURLs = Notification.Name("openExternalURLs")
}

class AppDelegate: NSObject, NSApplicationDelegate {
    weak var store: FolderStore?

    func application(_ application: NSApplication, openFile filename: String) -> Bool {
        let url = URL(fileURLWithPath: filename)
        handle(urls: [url])
        return true
    }

    func application(_ application: NSApplication, openFiles filenames: [String]) {
        let urls = filenames.map { URL(fileURLWithPath: $0) }
        handle(urls: urls)
        application.reply(toOpenOrPrint: .success)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    private func handle(urls: [URL]) {
        guard let store = store else {
            // 尚未初始化时先发通知，MainContentView 会在 onReceive 中处理
            NotificationCenter.default.post(name: .openExternalURLs, object: urls)
            return
        }
        Task { @MainActor in
            let imageURLs = urls.filter { ImageDiscovery.isImageFile($0) }
            let dirURLs = urls.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true }
            if !imageURLs.isEmpty {
                store.revealExternalImages(imageURLs)
            } else if let dir = dirURLs.first {
                store.openFolder(dir)
            }
            NSApp.activate(ignoringOtherApps: true)
            if let w = NSApp.keyWindow ?? NSApp.mainWindow ?? NSApp.windows.first(where: { $0.identifier?.rawValue == "main" }) {
                w.makeKeyAndOrderFront(nil)
            }
        }
    }
}

@main
struct PictoolApp: App {

    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @State private var store = FolderStore()

    var body: some Scene {
        Window("PureView", id: "main") {
            MainContentView()
                .environment(store)
                .ignoresSafeArea(.container, edges: .top)
                .onAppear { delegate.store = store }
                .onReceive(NotificationCenter.default.publisher(for: .openExternalURLs)) { note in
                    if let urls = note.object as? [URL] {
                        if urls.count == 1, let url = urls.first {
                            var isDir: ObjCBool = false
                            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
                                store.openFolder(url)
                            } else {
                                store.revealExternalImages(urls)
                            }
                        } else {
                            store.revealExternalImages(urls)
                        }
                    }
                }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1024, height: 680)
        .handlesExternalEvents(matching: Set(arrayLiteral: "*"))
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("打开文件夹…") { store.openFolderPanel() }
                    .keyboardShortcut("o", modifiers: .command)
                    .disabled(store.isModalPresented)
                Button("刷新") { store.refreshCurrentFolder() }
                    .keyboardShortcut("r", modifiers: .command)
                    .disabled(store.selectedFolder == nil || store.isModalPresented)
            }
            CommandGroup(replacing: .printItem) {
                Button("打印…") { store.requestPrint() }
                    .keyboardShortcut("p", modifiers: .command)
                    .disabled(store.currentImage == nil || store.isModalPresented)
            }
            CommandMenu("图片") {
                // 裸键与方向键在模态面板打开时一律失效,否则会在面板背后改动浏览状态
                Button("上一张") { store.step(-1) }
                    .keyboardShortcut(.leftArrow, modifiers: [])
                    .disabled(!store.canStep(-1) || store.isModalPresented)
                Button("下一张") { store.step(1) }
                    .keyboardShortcut(.rightArrow, modifiers: [])
                    .disabled(!store.canStep(1) || store.isModalPresented)
                Divider()
                Button("适配窗口") { store.requestZoom(.fit) }
                    .keyboardShortcut("0", modifiers: [])
                    .disabled(store.currentImage == nil || store.isModalPresented)
                Button("实际大小") { store.requestZoom(.actualSize) }
                    .keyboardShortcut("1", modifiers: [])
                    .disabled(store.currentImage == nil || store.isModalPresented)
                Button("放大") { store.requestZoom(.zoomIn) }
                    .keyboardShortcut("=", modifiers: .command)
                    .disabled(store.currentImage == nil || store.isModalPresented)
                Button("缩小") { store.requestZoom(.zoomOut) }
                    .keyboardShortcut("-", modifiers: .command)
                    .disabled(store.currentImage == nil || store.isModalPresented)
                Divider()
                Button("信息面板") { store.showInspector.toggle() }
                    .keyboardShortcut("i", modifiers: [])
                    .disabled(store.isModalPresented)
                Button(store.isImmersive ? "退出只看图" : "只看图") {
                    store.toggleImmersive()
                }
                    .keyboardShortcut("f", modifiers: [])
                    .disabled((store.currentImage == nil && !store.isImmersive) || store.isModalPresented)
                Button(
                    store.isSlideshowActive
                        ? (store.isSlideshowPaused ? "继续幻灯片" : "暂停幻灯片")
                        : "幻灯片播放"
                ) {
                    store.toggleSlideshow()
                }
                    .keyboardShortcut(.space, modifiers: [])
                    .disabled(store.currentImage == nil || store.isModalPresented || store.images.count < 2)
                Button("裁切…") { store.requestCrop() }
                    .keyboardShortcut("c", modifiers: [])
                    .disabled(store.currentImage == nil || store.isModalPresented)
                Divider()
                Button("顺时针旋转 90°") { store.requestRotate() }
                    .keyboardShortcut("r", modifiers: [.command, .option])
                    .disabled(store.currentImage == nil || store.isModalPresented)
            }
        }
        Settings {
            SettingsView()
        }
    }
}
