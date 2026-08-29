import SwiftUI
import AppKit

/// 纯 SwiftUI 顶部栏：32pt，承载全部功能按钮，样式完全可定制。
/// 与系统标题栏解耦（hiddenTitleBar + WindowChrome），高度/背景/圆角均可改。
struct PureHeader: View {

    @Environment(FolderStore.self) private var store
    /// 侧栏可见时的宽度,用来把顶栏左段切成独立的「侧栏顶」
    var sidebarWidth: CGFloat? = nil
    @AppStorage(SidebarTopStyle.storageKey) private var sidebarTopStyle = SidebarTopStyle.defaultValue
    @AppStorage(CanvasBackground.storageKey) private var canvasBackground = CanvasBackground.defaultValue

    private var splitsSidebarTop: Bool {
        sidebarWidth != nil && sidebarTopStyle == .followSidebar
    }

    private var mainHeaderColorScheme: ColorScheme {
        ChromeTheme.colorScheme(for: canvasBackground)
    }

    var body: some View {
        Group {
            if splitsSidebarTop, let width = sidebarWidth {
                HStack(spacing: 0) {
                    leftCluster
                        .padding(.leading, 12)
                        .frame(width: width, alignment: .leading)
                        .clipped()
                        // 左段(侧栏开关/标题)与右段一样跟随画布背景明暗,
                        // 黑画布下用亮色,否则黑底黑字看不清
                        .environment(\.colorScheme, mainHeaderColorScheme)
                    rightCluster
                        .padding(.horizontal, 12)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        .environment(\.colorScheme, mainHeaderColorScheme)
                }
            } else {
                HStack(spacing: 5) {
                    leftCluster
                    Spacer()
                    rightCluster
                }
                .padding(.horizontal, 12)
                .environment(\.colorScheme, mainHeaderColorScheme)
            }
        }
        .frame(height: 32)
        .frame(maxWidth: .infinity)
        // 拖拽区必须与背景同层且在其之上:分成两个 .background 时后挂的那层在更底下,
        // 会被不透明的 headerBackground 完全遮住,双击缩放收不到事件。
        .background {
            ZStack {
                headerBackground
                // 自定义拖拽区：空白处拖动窗口，双击缩放；按钮区域不受影响
                Color.clear
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0, coordinateSpace: .global)
                            .onChanged { _ in
                                if let window = NSApp.keyWindow ?? NSApp.mainWindow,
                                   let event = NSApp.currentEvent {
                                    window.performDrag(with: event)
                                }
                            }
                    )
                    .onTapGesture(count: 2) { NSApp.keyWindow?.zoom(nil) }
            }
        }
    }

    @ViewBuilder
    private var headerBackground: some View {
        if splitsSidebarTop, let width = sidebarWidth {
            HStack(spacing: 0) {
                SidebarTopBackground()
                    .frame(width: width)
                mainHeaderBackground
            }
        } else {
            mainHeaderBackground
        }
    }

    private var mainHeaderBackground: some View {
        MainChromeBackground(canvas: canvasBackground)
    }

    private var leftCluster: some View {
        HStack(spacing: 5) {
            NativeTrafficLights()
                .frame(width: NativeTrafficLights.width, height: NativeTrafficLights.height)
            HeaderButton("sidebar.leading", help: "显示/隐藏侧栏 (⌃⌘S)") {
                store.toggleSidebar()
            }
            Spacer().frame(width: 8)
            Text("PureView")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)
        }
    }

    private var rightCluster: some View {
        HStack(spacing: 5) {
            HeaderButton("folder.badge.plus", help: "打开图片文件夹 (⌘O)") {
                store.openFolderPanel()
            }
            HeaderDivider()
            HeaderButton("chevron.left", help: "上一张 (←)",
                         disabled: !store.canStep(-1)) { store.step(-1) }
            HeaderButton("chevron.right", help: "下一张 (→)",
                         disabled: !store.canStep(1)) { store.step(1) }
            HeaderDivider()
            HeaderButton("minus.magnifyingglass", help: "缩小 (⌘-)",
                         disabled: store.currentImage == nil) { store.requestZoom(.zoomOut) }
            HeaderButton("plus.magnifyingglass", help: "放大 (⌘=)",
                         disabled: store.currentImage == nil) { store.requestZoom(.zoomIn) }
            HeaderDivider()
            HeaderButton("rotate.right", help: "顺时针旋转 90°",
                         disabled: store.currentImage == nil) { store.requestRotate() }
            HeaderButton("crop", help: "裁切 (C)",
                         disabled: store.currentImage == nil) { store.requestCrop() }
            HeaderButton("printer", help: "打印 (⌘P)",
                         disabled: store.currentImage == nil) { store.requestPrint() }
            HeaderButton("info.circle", help: "图片信息 (I)") {
                store.showInspector.toggle()
            }
            HeaderButton(
                store.isSlideshowActive && !store.isSlideshowPaused ? "pause.circle" : "play.circle",
                help: store.isSlideshowActive && !store.isSlideshowPaused
                    ? "暂停幻灯片 (空格)"
                    : "幻灯片播放 (空格)",
                disabled: store.currentImage == nil || store.images.count < 2
            ) { store.toggleSlideshow() }
            HeaderDivider()
            HeaderButton(
                store.isImmersive ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right",
                help: store.isImmersive ? "退出只看图 (Esc / F)" : "只看图,隐藏所有界面 (F)",
                disabled: store.currentImage == nil && !store.isImmersive
            ) { store.toggleImmersive() }
        }
    }
}

private struct HeaderButton: View {
    let systemImage: String
    let help: String
    var disabled = false
    let action: () -> Void

    @State private var hovering = false

    init(_ systemImage: String, help: String, disabled: Bool = false, action: @escaping () -> Void) {
        self.systemImage = systemImage
        self.help = help
        self.disabled = disabled
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 12))
                .frame(width: 24, height: 20)
                .background(
                    hovering && !disabled ? Color.primary.opacity(0.08) : .clear,
                    in: RoundedRectangle(cornerRadius: 4)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled ? 0.35 : 1)
        .help(help)
        .onHover { hovering = $0 }
    }
}

private struct HeaderDivider: View {
    var body: some View { Divider().frame(height: 13) }
}

/// 把窗口自带的关闭/最小化/缩放按钮嵌进自定义顶栏,保留系统绘制、悬停符号和无障碍。
struct NativeTrafficLights: NSViewRepresentable {
    static let width: CGFloat = 56
    static let height: CGFloat = 16

    func makeNSView(context: Context) -> NativeTrafficLightsView {
        NativeTrafficLightsView()
    }

    func updateNSView(_ nsView: NativeTrafficLightsView, context: Context) {
        nsView.embedButtons()
    }
}

final class NativeTrafficLightsView: NSView {
    private var tracking: NSTrackingArea?
    private var hovering = false
    private static let buttonSpacing: CGFloat = 8
    private static let mouseInGroup = NSSelectorFromString("_setMouseInGroup:")

    override var isOpaque: Bool { false }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        embedButtons()
        DispatchQueue.main.async { [weak self] in self?.embedButtons() }
    }

    override func layout() {
        super.layout()
        embedButtons()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) {
        hovering = true
        applyGroupHover()
    }

    override func mouseExited(with event: NSEvent) {
        hovering = false
        applyGroupHover()
    }

    func embedButtons() {
        guard let window else { return }
        let types: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton]
        var x: CGFloat = 0
        for type in types {
            guard let button = window.standardWindowButton(type) else { continue }
            if button.superview !== self {
                button.removeFromSuperview()
                addSubview(button)
            }
            button.isHidden = false
            let size = button.frame.size.width > 1 ? button.frame.size : NSSize(width: 14, height: 16)
            let y = ((bounds.height - size.height) / 2).rounded(.toNearestOrAwayFromZero)
            button.setFrameOrigin(NSPoint(x: x, y: max(0, y)))
            x += size.width + Self.buttonSpacing
        }
        applyGroupHover()
    }

    private func applyGroupHover() {
        for type in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            guard let button = window?.standardWindowButton(type),
                  button.responds(to: Self.mouseInGroup) else { continue }
            button.perform(Self.mouseInGroup, with: NSNumber(value: hovering))
        }
    }
}

