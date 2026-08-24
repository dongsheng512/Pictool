import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// 主界面:纯 SwiftUI——hiddenTitleBar 无系统 header,
/// NavigationSplitView(侧栏 + 详情)+ 自定义 Overlay header + 信息面板 + 状态栏
struct MainContentView: View {

    @Environment(FolderStore.self) private var store
    @State private var showCropSheet = false
    @State private var isPreparingPrint = false
    @State private var showZoomMenu = false
    @State private var sidebarWidth: CGFloat = UserDefaults.standard.double(forKey: "sidebarWidth") > 0 ? UserDefaults.standard.double(forKey: "sidebarWidth") : 260
    @State private var dragStartWidth: CGFloat = 260
    @State private var isHoveringDivider = false
    @AppStorage(CanvasBackground.storageKey) private var canvasBackgroundRaw = CanvasBackground.defaultValue.rawValue

    var body: some View {
        @Bindable var store = store
        Group {
            if store.isImmersive {
                immersiveLayer
            } else {
                normalLayer
            }
        }
        .frame(minWidth: 960, minHeight: 600)
        .background(WindowChrome(immersive: store.isImmersive))
        .onAppear {
            runZoomSelfTestIfRequested()
            dragStartWidth = sidebarWidth
        }
        .onOpenURL { url in handleExternal(url) }
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            handleDrop(providers)
        }
        .overlay {
            if isPreparingPrint { ProgressView("正在准备打印…") }
        }
        .overlay(alignment: .topTrailing) {
            if store.isImmersive {
                Button {
                    store.toggleImmersive()
                } label: {
                    Image(systemName: "arrow.down.right.and.arrow.up.left")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.primary)
                        .frame(width: 28, height: 22)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 5))
                }
                .buttonStyle(.plain)
                .help("退出只看图 (Esc)")
                .padding(12)
            }
        }
        .onExitCommand {
            if store.isImmersive { store.toggleImmersive() }
        }
    }

    // MARK: - 纯净模式单独显示层：只显示图片，无任何 chrome
    private var immersiveLayer: some View {
        ZStack {
            ImageViewCanvas(
                file: store.currentImage,
                neighborURLs: store.neighborURLs,
                backgroundColor: CanvasBackground(rawValue: canvasBackgroundRaw)?.color
                    ?? CanvasBackground.defaultValue.color,
                zoomRequest: store.zoomRequest,
                rotateRequestToken: store.rotateRequestToken,
                stepDirection: store.lastStepDirection,
                onLoadingChange: { store.imageLoading = $0 },
                onScaleChange: { store.displayScale = $0 },
                onImageInfo: { store.displayInfo = $0 },
                onStep: { store.step($0) }
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ignoresSafeArea()
    }

    private var normalLayer: some View {
        ZStack(alignment: .top) {
            HStack(spacing: 0) {
                if store.sidebarVisible {
                    SidebarView()
                        .frame(width: sidebarWidth)
                        // 1px 分隔线贴在侧栏右边缘
                        .overlay(alignment: .trailing) {
                            Rectangle()
                                .fill(isHoveringDivider ? Color.black.opacity(0.14) : Color.black.opacity(0.07))
                                .frame(width: 1)
                        }
                        // 16pt 拖拽热区，居中于分隔线上（左右各 8pt），便于抓取
                        .overlay(alignment: .trailing) {
                            Color.clear
                                .frame(width: 16)
                                .contentShape(Rectangle())
                                .offset(x: 8)
                                .highPriorityGesture(
                                    DragGesture(minimumDistance: 0, coordinateSpace: .global)
                                        .onChanged { value in
                                            let next = dragStartWidth + value.translation.width
                                            sidebarWidth = min(400, max(180, next))
                                        }
                                        .onEnded { _ in dragStartWidth = sidebarWidth; UserDefaults.standard.set(sidebarWidth, forKey: "sidebarWidth") }
                                )
                                .onHover { inside in
                                    isHoveringDivider = inside
                                    if let w = NSApp.keyWindow ?? NSApp.mainWindow {
                                        w.isMovableByWindowBackground = !inside
                                    }
                                    if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
                                }
                        }
                        .transition(.move(edge: .leading).combined(with: .opacity))
                }
                detail
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .inspector(isPresented: Binding(get: { store.showInspector }, set: { store.showInspector = $0 })) {
                        InfoInspector(file: store.currentImage)
                    }
                    .sheet(isPresented: $showCropSheet) {
                        if let file = store.currentImage { CropView(file: file) }
                    }
                    .onChange(of: store.cropRequestToken) { _, _ in
                        showCropSheet = store.currentImage != nil
                    }
                    .onChange(of: store.printRequestToken) { _, _ in
                        prepareAndPrint()
                    }
            }
            .padding(.top, 32)
            PureHeader(
                sidebarWidth: store.sidebarVisible ? sidebarWidth : nil,
                sidebarVisible: store.sidebarVisible
            )
                .frame(maxWidth: .infinity, alignment: .top)
        }
        .ignoresSafeArea(edges: .top)
        .onDisappear {
            NSApp.keyWindow?.isMovableByWindowBackground = true
            NSApp.mainWindow?.isMovableByWindowBackground = true
        }
    }

    private func prepareAndPrint() {
        guard let file = store.currentImage, !isPreparingPrint else { return }
        isPreparingPrint = true
        let url = file.url
        Task {
            let image = await Task.detached(priority: .userInitiated) {
                try? ImageLoader.decode(url: url, maxPixelSize: nil)
            }.value
            isPreparingPrint = false
            guard let image else { return }
            await MainActor.run {
                PrintService.print(image: image)
            }
        }
    }

    // MARK: 详情区

    private var detail: some View {
        VStack(spacing: 0) {
            ZStack {
                ImageViewCanvas(
                    file: store.currentImage,
                    neighborURLs: store.neighborURLs,
                    backgroundColor: CanvasBackground(rawValue: canvasBackgroundRaw)?.color
                        ?? CanvasBackground.defaultValue.color,
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
            if !store.isImmersive {
                statusBar
            }
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
        .background(SoftWhiteOverlay())
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

    /// 柔和磨砂白底，与侧栏/header 形成同色系过渡，避免纯白刺眼
    private struct FrostedWhiteBackground: NSViewRepresentable {
        func makeNSView(context: Context) -> NSVisualEffectView {
            let view = NSVisualEffectView()
            view.material = .headerView
            view.blendingMode = .withinWindow
            view.state = .followsWindowActiveState
            return view
        }

        func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
    }

    private struct SoftWhiteOverlay: View {
        var body: some View {
            ZStack {
                FrostedWhiteBackground()
                // 柔和米白提亮，#FAFAFB @ 0.72
                Color(red: 0.985, green: 0.985, blue: 0.987).opacity(0.22)
            }
        }
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
        .background {
            ZStack {
                HeaderMaterial()
                Color.white.opacity(0.22)
            }
        }
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

/// 窗口 chrome：移除原生标题栏，仅保留 PureHeader 单层
private struct WindowChrome: NSViewRepresentable {
    let immersive: Bool
    func makeNSView(context: Context) -> NSView { ChromeView() }
    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? ChromeView)?.immersive = immersive
        (nsView as? ChromeView)?.apply()
    }
}
private final class ChromeView: NSView {
    var immersive = false
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        apply()
        DispatchQueue.main.async { [weak self] in self?.stripTitlebar() }
    }
    override func viewDidMoveToSuperview() { super.viewDidMoveToSuperview(); apply() }
    func apply() { stripTitlebar() }
    private func stripTitlebar() {
        guard let window else { return }
        window.styleMask.insert(.fullSizeContentView)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.title = ""
        window.isMovableByWindowBackground = true
        window.backgroundColor = .clear
        window.isOpaque = false
        let radius: CGFloat = immersive ? 0 : 10
        window.contentView?.wantsLayer = true
        window.contentView?.layer?.cornerRadius = radius
        window.contentView?.layer?.masksToBounds = true
        window.contentView?.superview?.wantsLayer = true
        window.contentView?.superview?.layer?.cornerRadius = radius
        window.contentView?.superview?.layer?.masksToBounds = true
        // 隐藏原生红绿灯（PureHeader 已自绘）；纯净模式直接隐藏整个原生标题栏，不留透明条
        for b in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            window.standardWindowButton(b)?.isHidden = true
        }
        window.standardWindowButton(.closeButton)?.superview?.isHidden = true
        if let theme = window.contentView?.superview {
            for sub in theme.subviews where String(describing: type(of: sub)).contains("Titlebar") {
                sub.isHidden = immersive
                sub.frame.size.height = immersive ? 0 : 28
            }
        }
    }
}

