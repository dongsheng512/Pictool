import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// 主界面:NavigationSplitView(边栏 + 详情)+ 尾随信息面板 + 底部状态栏
struct MainContentView: View {

    @Environment(FolderStore.self) private var store
    @State private var showCropSheet = false
    @State private var showPrintSheet = false
    @State private var showZoomMenu = false

    var body: some View {
        @Bindable var store = store
        NavigationSplitView {
            SidebarView()
        } detail: {
            detail
                .inspector(isPresented: $store.showInspector) {
                    InfoInspector(file: store.currentImage)
                }
                .toolbar { toolbarContent }
                .sheet(isPresented: $showCropSheet) {
                    if let file = store.currentImage { CropView(file: file) }
                }
                .sheet(isPresented: $showPrintSheet) {
                    if let file = store.currentImage { PrintOptionsView(file: file) }
                }
                .onChange(of: store.cropRequestToken) { _, _ in
                    showCropSheet = store.currentImage != nil
                }
                .onChange(of: store.printRequestToken) { _, _ in
                    showPrintSheet = store.currentImage != nil
                }
        }
        .frame(minWidth: 960, minHeight: 600)
        .onAppear { runZoomSelfTestIfRequested() }
        .onOpenURL { url in handleExternal(url) }
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            handleDrop(providers)
        }
    }

    // MARK: 详情区

    private var detail: some View {
        VStack(spacing: 0) {
            ZStack {
                ImageViewCanvas(
                    file: store.currentImage,
                    neighborURLs: store.neighborURLs,
                    zoomRequest: store.zoomRequest,
                    rotateRequestToken: store.rotateRequestToken,
                    stepDirection: store.lastStepDirection,
                    onLoadingChange: { store.imageLoading = $0 },
                    onScaleChange: { store.displayScale = $0 },
                    onImageInfo: { store.displayInfo = $0 },
                    onStep: { store.step($0) }
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                if store.roots.isEmpty {
                    welcomeOverlay
                } else if store.imageLoading && store.displayInfo.pixelWidth == 0 {
                    ProgressView()
                        .controlSize(.regular)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let current = store.currentImage, store.displayInfo.pixelWidth == 0, !store.imageLoading {
                    VStack(spacing: 10) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.system(size: 30))
                            .foregroundStyle(.secondary)
                        Text("无法显示“\(current.name)”")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            Divider()
            statusBar
        }
        // 缩放下拉用窗口内 overlay 实现,保证弹出面板被窗口边界裁剪
        .overlay {
            if showZoomMenu {
                ZStack(alignment: .bottomTrailing) {
                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture { showZoomMenu = false }
                    zoomDropdown
                        .padding(.trailing, 8)
                        .padding(.bottom, 32)
                }
                .onExitCommand { showZoomMenu = false }
                .transition(.opacity)
            }
        }
    }

    private var welcomeOverlay: some View {
        VStack(spacing: 14) {
            Image(systemName: "photo.on.rectangle.angled")
                .font(.system(size: 52))
                .foregroundStyle(.tertiary)
            Text("打开一个图片文件夹开始浏览")
                .font(.title3)
                .foregroundStyle(.secondary)
            Button("打开文件夹…") { store.openFolderPanel() }
                .keyboardShortcut("o", modifiers: .command)
            Text("也可以直接把图片或文件夹拖入窗口")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(FrostedWhiteBackground())
    }

    /// 缩放下拉的菜单项(悬停高亮)
    private struct ZoomMenuItem: View {
        let title: String
        let action: () -> Void

        @State private var hovering = false

        init(_ title: String, action: @escaping () -> Void) {
            self.title = title
            self.action = action
        }

        var body: some View {
            Button(action: action) {
                Text(title)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .background(
                hovering ? Color.accentColor.opacity(0.18) : Color.clear,
                in: RoundedRectangle(cornerRadius: 4)
            )
            .onHover { hovering = $0 }
        }
    }

    /// 磨砂感白色底(NSVisualEffectView 浅色材质),用于未打开图片的初始状态
    private struct FrostedWhiteBackground: NSViewRepresentable {
        func makeNSView(context: Context) -> NSVisualEffectView {
            let view = NSVisualEffectView()
            view.material = .contentBackground
            view.blendingMode = .behindWindow
            view.state = .active
            // 固定浅色外观,深色系统主题下也保持白色磨砂
            view.appearance = NSAppearance(named: .vibrantLight)
            return view
        }

        func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
    }

    private var statusBar: some View {
        HStack(spacing: 10) {
            if let image = store.currentImage {
                // 身份组:文件名(主色强调)
                Text(image.name)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(.primary)

                let meta = statusMetaItems
                if !meta.isEmpty {
                    statusBarDivider
                    // 元数据组:中点轻连接,比空格更有"同属一组"的暗示
                    HStack(spacing: 5) {
                        ForEach(meta.indices, id: \.self) { i in
                            if i > 0 {
                                Text("·")
                                    .foregroundStyle(.tertiary)
                            }
                            Text(meta[i])
                                .monospacedDigit()
                        }
                    }
                }

                statusBarDivider
                // 导航组
                Text("\(store.currentIndex + 1) / \(store.images.count)")
                    .monospacedDigit()
                if store.imageLoading {
                    ProgressView()
                        .controlSize(.mini)
                }
                Spacer()
                zoomMenu
            } else {
                Text("未打开图片").foregroundStyle(.secondary)
                Spacer()
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    /// 元数据段:格式 / 像素尺寸 / 动图帧数(按可用性拼接)
    private var statusMetaItems: [String] {
        var items: [String] = []
        if !store.displayInfo.formatName.isEmpty {
            items.append(store.displayInfo.formatName)
        }
        if store.displayInfo.pixelWidth > 0 {
            items.append("\(store.displayInfo.pixelWidth) × \(store.displayInfo.pixelHeight)")
        }
        if store.displayInfo.isAnimated {
            items.append("\(store.displayInfo.frameCount) 帧")
        }
        return items
    }

    /// 状态栏分组竖线
    private var statusBarDivider: some View {
        Divider()
            .frame(height: 11)
    }

    private var zoomMenu: some View {
        Button {
            showZoomMenu.toggle()
        } label: {
            Text("\(Int((store.displayScale * 100).rounded()))%")
                .font(.caption)
                .monospacedDigit()
                .frame(minWidth: 56, alignment: .trailing)
        }
        .buttonStyle(.plain)
        .disabled(store.currentImage == nil)
    }

    /// 窗口内下拉面板(替代 NSMenu 弹出,不超出窗口边界)
    private var zoomDropdown: some View {
        VStack(alignment: .leading, spacing: 2) {
            ZoomMenuItem("适配窗口") {
                showZoomMenu = false
                store.requestZoom(.fit)
            }
            ZoomMenuItem("实际大小 (100%)") {
                showZoomMenu = false
                store.requestZoom(.actualSize)
            }
        }
        .padding(6)
        .frame(width: 170, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(.separator)
        )
        .shadow(color: .black.opacity(0.18), radius: 10, y: 3)
    }

    // MARK: 工具栏

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Button {
                store.openFolderPanel()
            } label: {
                Label("打开文件夹", systemImage: "folder.badge.plus")
            }
            .help("打开图片文件夹 (⌘O)")
        }
        ToolbarItem(placement: .navigation) {
            Button {
                store.refreshCurrentFolder()
            } label: {
                Label("刷新", systemImage: "arrow.clockwise")
            }
            .help("刷新当前文件夹 (⌘R)")
            .disabled(store.selectedFolder == nil)
        }

        ToolbarItemGroup {
            Button { store.step(-1) } label: {
                Label("上一张", systemImage: "chevron.left")
            }
            .help("上一张 (←)")
            .disabled(store.images.isEmpty)

            Button { store.step(1) } label: {
                Label("下一张", systemImage: "chevron.right")
            }
            .help("下一张 (→)")
            .disabled(store.images.isEmpty)

            Divider()

            Button { store.requestZoom(.zoomOut) } label: {
                Label("缩小", systemImage: "minus.magnifyingglass")
            }
            .help("缩小 (⌘-)")
            .disabled(store.currentImage == nil)

            Button { store.requestZoom(.zoomIn) } label: {
                Label("放大", systemImage: "plus.magnifyingglass")
            }
            .help("放大 (⌘=)")
            .disabled(store.currentImage == nil)
        }

        ToolbarItemGroup(placement: .primaryAction) {
            Button {
                store.requestRotate()
            } label: {
                Label("旋转", systemImage: "rotate.right")
            }
            .help("顺时针旋转 90°")
            .disabled(store.currentImage == nil)

            Button {
                store.showInspector.toggle()
            } label: {
                Label("信息", systemImage: "info.circle")
            }
            .help("图片信息 (I)")

            Button {
                store.requestCrop()
            } label: {
                Label("裁切", systemImage: "crop")
            }
            .help("裁切 (C)")
            .disabled(store.currentImage == nil)

            Button {
                store.requestPrint()
            } label: {
                Label("打印", systemImage: "printer")
            }
            .help("打印 (⌘P)")
            .disabled(store.currentImage == nil)
        }
    }

    // MARK: 自测模式(--zoom-test):自动执行一组缩放动作并记录日志

    private func runZoomSelfTestIfRequested() {
#if DEBUG
        guard ProcessInfo.processInfo.arguments.contains("--zoom-test") else { return }
        Task { @MainActor in
            let wait: UInt64 = 1_200_000_000
            store.openFolder(URL(fileURLWithPath: "/tmp/pictool_test"))
            try? await Task.sleep(nanoseconds: wait)
            FileHandle.standardError.write(Data("[test] zoomIn #1\n".utf8))
            store.requestZoom(.zoomIn)
            try? await Task.sleep(nanoseconds: wait)
            FileHandle.standardError.write(Data("[test] zoomIn #2\n".utf8))
            store.requestZoom(.zoomIn)
            try? await Task.sleep(nanoseconds: wait)
            FileHandle.standardError.write(Data("[test] simulate pinch 1.5x\n".utf8))
            NotificationCenter.default.post(name: Notification.Name("PictoolSimPinch"),
                                            object: nil, userInfo: ["m": 1.5])
            try? await Task.sleep(nanoseconds: wait)
            FileHandle.standardError.write(Data("[test] fit\n".utf8))
            store.requestZoom(.fit)
            try? await Task.sleep(nanoseconds: wait)
            FileHandle.standardError.write(Data("[test] DONE\n".utf8))
        }
#endif
    }

    // MARK: 拖放 / 外部打开

    @MainActor
    private func handleExternal(_ url: URL) {
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue {
            store.openFolder(url)
        } else if ImageDiscovery.isImageFile(url) {
            store.revealExternalImage(url)
        }
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        _ = provider.loadObject(ofClass: URL.self) { url, _ in
            guard let url else { return }
            Task { @MainActor in
                handleExternal(url)
            }
        }
        return true
    }
}
