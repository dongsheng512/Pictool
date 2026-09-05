import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// 兼容入口:裁切快捷键停在裁切工具。实现见 `EditView`。
struct CropView: View {
    let file: ImageFile
    var initialQuarterTurns = 0

    var body: some View {
        EditView(file: file, initialQuarterTurns: initialQuarterTurns, initialTool: .crop)
    }
}

// MARK: - 选区画布

struct CropCanvas: View {

    let image: NSImage
    @Binding var selection: CGRect
    /// 比例锁定的目标宽高比(像素空间);nil 时自由拖动
    let lockAspect: CGFloat?
    /// 预览图自身的宽高比。既用于布局,也用于把像素比例折算到归一化选区空间
    let previewAspect: CGFloat
    /// 拖动真正开始改变选区时回调(压撤销栈,整个拖动算一步)
    let onInteractionStart: () -> Void
    var overlay: NSImage? = nil
    var watermark: WatermarkSettings = WatermarkSettings()

    @State private var dragBaseline: CGRect?
    @State private var dragStartPoint: CGPoint?
    @State private var undoGroupOpen = false
    @State private var activeHandle: CropHandle = .move

    var body: some View {
        GeometryReader { geo in
            let fit = fittedRect(container: geo.size)
            let minNorm = max(0.02, 18 / max(fit.width, 1))
            let shown = displayRect(fit: fit)
            ZStack(alignment: .topLeading) {
                Image(nsImage: image)
                    .resizable()
                    .frame(width: fit.width, height: fit.height)
                    .offset(x: fit.minX, y: fit.minY)
                    .allowsHitTesting(false)

                if let overlay {
                    Image(nsImage: overlay)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: fit.width, height: fit.height)
                        .offset(x: fit.minX, y: fit.minY)
                        .allowsHitTesting(false)
                }

                dimming(fit: fit)

                // 水印按裁切输出画幅布局(与导出一致),落在选框内
                WatermarkStampLayer(settings: watermark, frame: shown)

                thirds(rect: shown)
                    .allowsHitTesting(false)

                Rectangle()
                    .strokeBorder(Color.white, lineWidth: 1.5)
                    .frame(width: shown.width, height: shown.height)
                    .offset(x: shown.minX, y: shown.minY)
                    .allowsHitTesting(false)

                ForEach(Array(handleSpecs(rect: shown).enumerated()), id: \.offset) { _, spec in
                    Rectangle()
                        .fill(Color.white)
                        .frame(width: spec.size, height: spec.size)
                        .overlay(
                            Rectangle()
                                .strokeBorder(Color.black.opacity(0.55), lineWidth: 0.5)
                        )
                        .shadow(radius: 1)
                        .frame(width: 20, height: 20)
                        .offset(x: spec.point.x - 10, y: spec.point.y - 10)
                        .allowsHitTesting(false)
                }

                // 显式给尺寸:NSViewRepresentable 没有 intrinsicContentSize,
                // 不钉住就只有被命中的那一小块能拖,其余区域照样漏给窗口。
                CanvasMouseCatcher(
                    onDown: { point in handleDown(point, fit: fit, minNorm: minNorm) },
                    onDrag: { point in handleDrag(point, fit: fit, minNorm: minNorm) },
                    onUp: handleUp
                )
                .frame(width: geo.size.width, height: geo.size.height)
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
        }
    }

    /// AppKit 坐标(isFlipped,左上原点)与 SwiftUI 绘制共用同一套 fit。
    private func handleDown(_ point: CGPoint, fit: CGRect, minNorm: CGFloat) {
        dragStartPoint = point
        dragBaseline = selection
        activeHandle = hitHandle(at: point, fit: fit)
        // 压栈推迟到首次真正拖动:空点不产生"假撤销"
    }

    private func handleDrag(_ point: CGPoint, fit: CGRect, minNorm: CGFloat) {
        guard let base = dragBaseline, let start = dragStartPoint else { return }
        if !undoGroupOpen {
            undoGroupOpen = true
            onInteractionStart()
        }
        let dx = (point.x - start.x) / max(fit.width, 1)
        let dy = (point.y - start.y) / max(fit.height, 1)
        apply(kind: activeHandle, base: base, dx: dx, dy: dy, minNorm: minNorm)
    }

    private func handleUp() {
        dragBaseline = nil
        dragStartPoint = nil
        undoGroupOpen = false
        activeHandle = .move
    }

    private func hitHandle(at location: CGPoint, fit: CGRect) -> CropHandle {
        let rect = displayRect(fit: fit)
        let hot: CGFloat = 16
        for spec in handleSpecs(rect: rect) {
            if hypot(location.x - spec.point.x, location.y - spec.point.y) <= hot {
                return spec.kind
            }
        }
        return .move
    }

    private func thirds(rect: CGRect) -> some View {
        Path { p in
            for i in 1...2 {
                let x = rect.minX + rect.width * CGFloat(i) / 3
                let y = rect.minY + rect.height * CGFloat(i) / 3
                p.move(to: CGPoint(x: x, y: rect.minY)); p.addLine(to: CGPoint(x: x, y: rect.maxY))
                p.move(to: CGPoint(x: rect.minX, y: y)); p.addLine(to: CGPoint(x: rect.maxX, y: y))
            }
        }
        .stroke(Color.white.opacity(0.45), lineWidth: 0.5)
    }

    private func fittedRect(container: CGSize) -> CGRect {
        let aspect = previewAspect > 0 ? previewAspect : 1
        let scale = min(container.width / aspect, container.height)
        let width = aspect * scale
        let height = scale
        return CGRect(x: (container.width - width) / 2,
                      y: (container.height - height) / 2,
                      width: width, height: height)
    }

    /// 选区之外的半透明遮罩(奇偶填充)
    private func dimming(fit: CGRect) -> some View {
        Path { path in
            path.addRect(fit)
            path.addRect(displayRect(fit: fit))
        }
        .fill(Color.black.opacity(0.5), style: FillStyle(eoFill: true))
        .allowsHitTesting(false)
    }

    private func displayRect(fit: CGRect) -> CGRect {
        CGRect(x: fit.minX + selection.minX * fit.width,
               y: fit.minY + selection.minY * fit.height,
               width: selection.width * fit.width,
               height: selection.height * fit.height)
    }

    private struct HandleSpec {
        let kind: CropHandle
        let point: CGPoint
        let size: CGFloat
    }

    private func handleSpecs(rect: CGRect) -> [HandleSpec] {
        let corner: CGFloat = 11
        let edge: CGFloat = 8
        return [
            HandleSpec(kind: .topLeft, point: CGPoint(x: rect.minX, y: rect.minY), size: corner),
            HandleSpec(kind: .topRight, point: CGPoint(x: rect.maxX, y: rect.minY), size: corner),
            HandleSpec(kind: .bottomLeft, point: CGPoint(x: rect.minX, y: rect.maxY), size: corner),
            HandleSpec(kind: .bottomRight, point: CGPoint(x: rect.maxX, y: rect.maxY), size: corner),
            HandleSpec(kind: .top, point: CGPoint(x: rect.midX, y: rect.minY), size: edge),
            HandleSpec(kind: .bottom, point: CGPoint(x: rect.midX, y: rect.maxY), size: edge),
            HandleSpec(kind: .left, point: CGPoint(x: rect.minX, y: rect.midY), size: edge),
            HandleSpec(kind: .right, point: CGPoint(x: rect.maxX, y: rect.midY), size: edge),
        ]
    }

    private func apply(kind: CropHandle, base: CGRect, dx: CGFloat, dy: CGFloat, minNorm: CGFloat) {
        var minX = base.minX, minY = base.minY
        var maxX = base.maxX, maxY = base.maxY
        switch kind {
        case .move:
            minX += dx; maxX += dx; minY += dy; maxY += dy
        case .topLeft: minX += dx; minY += dy
        case .topRight: maxX += dx; minY += dy
        case .bottomLeft: minX += dx; maxY += dy
        case .bottomRight: maxX += dx; maxY += dy
        case .top: minY += dy
        case .bottom: maxY += dy
        case .left: minX += dx
        case .right: maxX += dx
        }
        let free = CGRect(x: min(minX, maxX), y: min(minY, maxY),
                          width: abs(maxX - minX), height: abs(maxY - minY))

        // 比例约束:锚点、尺寸、夹取全部收口在纯函数里(可单测)
        if let aspect = lockAspect {
            // 比例预设是像素空间的,必须连同图片比例一起交给纯函数折算到归一化空间
            selection = CropMath.ratioLockedRect(free: free, base: base, handle: kind,
                                                 aspect: aspect, imageAspect: previewAspect,
                                                 minSize: minNorm)
        } else {
            selection = CropMath.clampedNormalized(free, minSize: minNorm)
        }
    }
}

/// 编辑画布的鼠标入口。SwiftUI `DragGesture` 不会消费 AppKit `mouseDown`,
/// 而 hiddenTitleBar 窗口默认 `isMovableByWindowBackground`,于是拖手柄/画笔会变成拖窗口。
///
/// 这里用 NSView 自己吃事件,并用 `nextEvent` 跟踪循环把 dragged/up 从窗口拖移里抢走。
struct CanvasMouseCatcher: NSViewRepresentable {
    var onDown: (CGPoint) -> Void
    var onDrag: (CGPoint) -> Void
    var onUp: () -> Void
    /// 常规光标(按工具设置);悬停到可交互对象上时换手型
    var baseCursor: NSCursor = .arrow
    /// 悬停命中测试;nil 表示本画布无可交互对象提示(裁切画布)
    var hoverHitTest: ((CGPoint) -> Bool)?
    /// 右键菜单;返回 nil 表示此处无菜单
    var contextMenuProvider: ((CGPoint) -> NSMenu?)?
    /// 滚轮/触控板滑动(dx/dy 容器坐标增量,command 是否按住)
    var onScroll: ((_ dx: CGFloat, _ dy: CGFloat, _ commandHeld: Bool) -> Void)?
    /// 双指捏合(factor = 1 + magnification,anchor 容器坐标)
    var onMagnify: ((_ factor: CGFloat, _ anchor: CGPoint) -> Void)?
    /// 空格拖拽平移(translation = 相对手势起点的位移)
    var onPanStart: (() -> Void)?
    var onPanChange: ((_ translation: CGPoint) -> Void)?
    var onPanEnd: (() -> Void)?
    /// 空格平移总开关(文字草稿聚焦时关闭,空格让位给文本输入)
    var spacePanEnabled: Bool = true

    func makeNSView(context: Context) -> Catcher {
        let view = Catcher()
        apply(view)
        return view
    }

    func updateNSView(_ nsView: Catcher, context: Context) {
        apply(nsView)
    }

    private func apply(_ view: Catcher) {
        view.onDown = onDown
        view.onDrag = onDrag
        view.onUp = onUp
        view.baseCursor = baseCursor
        view.hoverHitTest = hoverHitTest
        view.contextMenuProvider = contextMenuProvider
        view.onScroll = onScroll
        view.onMagnify = onMagnify
        view.onPanStart = onPanStart
        view.onPanChange = onPanChange
        view.onPanEnd = onPanEnd
        view.spacePanEnabled = spacePanEnabled
    }

    final class Catcher: NSView {
        var onDown: ((CGPoint) -> Void)?
        var onDrag: ((CGPoint) -> Void)?
        var onUp: (() -> Void)?
        var baseCursor: NSCursor = .arrow
        var hoverHitTest: ((CGPoint) -> Bool)?
        var contextMenuProvider: ((CGPoint) -> NSMenu?)?
        var onScroll: ((_ dx: CGFloat, _ dy: CGFloat, _ commandHeld: Bool) -> Void)?
        var onMagnify: ((_ factor: CGFloat, _ anchor: CGPoint) -> Void)?
        var onPanStart: (() -> Void)?
        var onPanChange: ((_ translation: CGPoint) -> Void)?
        var onPanEnd: (() -> Void)?
        var spacePanEnabled = true
        private var tracking = false
        private var hovering = false
        private var spaceDown = false
        private var panStart: CGPoint?
        private var keyMonitor: Any?

        override var isFlipped: Bool { true }
        override var mouseDownCanMoveWindow: Bool { false }
        override var acceptsFirstResponder: Bool { true }

        /// 传进来的点在父视图坐标系,必须先转换再与 bounds 比较。
        override func hitTest(_ point: NSPoint) -> NSView? {
            bounds.contains(convert(point, from: superview)) ? self : nil
        }

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window != nil {
                installKeyMonitor()
            } else {
                spaceDown = false
                removeKeyMonitor()
            }
        }

        /// 只观察不消费:空格按下态用于「按住空格拖拽平移」;草稿聚焦时 spacePanEnabled 关,不进平移态。
        private func installKeyMonitor() {
            guard keyMonitor == nil else { return }
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self] event in
                if event.keyCode == 49, let self {
                    self.spaceDown = self.spacePanEnabled && event.type == .keyDown
                }
                return event
            }
        }

        private func removeKeyMonitor() {
            if let keyMonitor {
                NSEvent.removeMonitor(keyMonitor)
                self.keyMonitor = nil
            }
        }

        deinit { removeKeyMonitor() }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if !trackingAreas.contains(where: { $0.owner === self }) {
                addTrackingArea(NSTrackingArea(
                    rect: .zero,
                    options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect],
                    owner: self
                ))
            }
        }

        override func mouseMoved(with event: NSEvent) {
            let point = convert(event.locationInWindow, from: nil)
            guard bounds.contains(point), let test = hoverHitTest else {
                setHovering(false)
                return
            }
            setHovering(test(point))
        }

        override func mouseExited(with event: NSEvent) {
            setHovering(false)
        }

        private func setHovering(_ value: Bool) {
            guard hovering != value else { return }
            hovering = value
            window?.invalidateCursorRects(for: self)
        }

        override func resetCursorRects() {
            addCursorRect(bounds, cursor: hovering ? .pointingHand : baseCursor)
        }

        override func menu(for event: NSEvent) -> NSMenu? {
            guard let provider = contextMenuProvider else { return super.menu(for: event) }
            let point = convert(event.locationInWindow, from: nil)
            guard bounds.contains(point) else { return super.menu(for: event) }
            return provider(point)
        }

        /// 非精确 delta(普通滚轮一格 ≈ ±10)放大到可用步长
        override func scrollWheel(with event: NSEvent) {
            let dx = event.scrollingDeltaX, dy = event.scrollingDeltaY
            guard dx != 0 || dy != 0 else { return }
            let scale: CGFloat = event.hasPreciseScrollingDeltas ? 1 : 4
            onScroll?(dx * scale, dy * scale, event.modifierFlags.contains(.command))
        }

        override func magnify(with event: NSEvent) {
            guard event.magnification != 0 else { return }
            onMagnify?(1 + event.magnification, convert(event.locationInWindow, from: nil))
        }

        override func mouseDown(with event: NSEvent) {
            // 不调用 super:NSView.mouseDown 会把事件交给窗口拖移。
            tracking = true
            setHovering(false)
            let point = convert(event.locationInWindow, from: nil)
            if spaceDown, spacePanEnabled {
                panStart = point
                onPanStart?()
            } else {
                onDown?(point)
            }
            runTrackingLoop()
        }

        /// 把随后的 dragged/up 从窗口 run loop 里抽走,避免「手势和拖窗口同时发生」。
        private func runTrackingLoop() {
            guard let window else {
                finishTracking()
                return
            }
            while tracking {
                guard let next = window.nextEvent(
                    matching: [.leftMouseDragged, .leftMouseUp],
                    until: .distantFuture,
                    inMode: .eventTracking,
                    dequeue: true
                ) else { break }
                let point = convert(next.locationInWindow, from: nil)
                switch next.type {
                case .leftMouseDragged:
                    if let start = panStart {
                        onPanChange?(CGPoint(x: point.x - start.x, y: point.y - start.y))
                    } else {
                        onDrag?(point)
                    }
                default:
                    finishTracking()
                }
            }
        }

        private func finishTracking() {
            guard tracking else { return }
            tracking = false
            if panStart != nil {
                panStart = nil
                onPanEnd?()
            } else {
                onUp?()
            }
        }

        override func viewWillMove(toWindow newWindow: NSWindow?) {
            if newWindow == nil { finishTracking() }
            super.viewWillMove(toWindow: newWindow)
        }
    }
}

/// 编辑会话期间关掉「点背景拖窗口」。由 EditView 挂上,消失时还原。
struct WindowBackgroundMoveLock: NSViewRepresentable {
    var allowMove: Bool

    func makeNSView(context: Context) -> LockView {
        let view = LockView()
        view.allowMove = allowMove
        return view
    }

    func updateNSView(_ view: LockView, context: Context) {
        view.allowMove = allowMove
        view.apply()
    }

    final class LockView: NSView {
        var allowMove = true
        private var holding = false
        override var mouseDownCanMoveWindow: Bool { allowMove }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            apply()
        }

        override func viewWillMove(toWindow newWindow: NSWindow?) {
            if newWindow == nil { release() }
            super.viewWillMove(toWindow: newWindow)
        }

        func apply() {
            if allowMove {
                release()
                WindowMoveControl.setBackgroundMove(true)
            } else {
                hold()
            }
        }

        private func hold() {
            guard !holding else { return }
            holding = true
            WindowMoveControl.pushEditLock()
        }

        private func release() {
            guard holding else { return }
            holding = false
            WindowMoveControl.popEditLock()
        }
    }
}

@MainActor
enum WindowMoveControl {
    /// 编辑会话持有锁时,其它调用方(侧栏分隔条、ChromeView 重挂)不能把背景拖移再打开。
    private static var editLockCount = 0

    static func pushEditLock() {
        editLockCount += 1
        apply(allowed: false)
    }

    static func popEditLock() {
        editLockCount = max(0, editLockCount - 1)
        apply(allowed: editLockCount == 0)
    }

    static func setBackgroundMove(_ allowed: Bool) {
        apply(allowed: allowed)
    }

    private static func apply(allowed: Bool) {
        let window = NSApp.windows.first { $0.identifier?.rawValue == "main" }
            ?? NSApp.mainWindow
            ?? NSApp.keyWindow
        window?.isMovableByWindowBackground = editLockCount > 0 ? false : allowed
    }
}

/// 把水印烙成透明图再铺进给定框(裁切选区 = 导出画幅)。
struct WatermarkStampLayer: View {
    let settings: WatermarkSettings
    let frame: CGRect

    var body: some View {
        if settings.hasContent, frame.width > 2, frame.height > 2, let image = stamp {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .frame(width: frame.width, height: frame.height)
                .offset(x: frame.minX, y: frame.minY)
                .allowsHitTesting(false)
        }
    }

    private var stamp: NSImage? {
        // 量化尺寸,拖选框时不要每像素重烙一遍。
        let width = max(64, min(1200, (frame.width * 2 / 8).rounded() * 8))
        let height = max(64, min(1200, (width * frame.height / max(frame.width, 1) / 8).rounded() * 8))
        let key = stampKey(width: Int(width), height: Int(height))
        if let cached = Self.cache.object(forKey: key) { return cached }
        guard let cg = WatermarkRenderer.overlay(
            settings, canvasSize: CGSize(width: width, height: height), force: true
        ) else { return nil }
        let image = NSImage(cgImage: cg, size: NSSize(width: frame.width, height: frame.height))
        Self.cache.setObject(image, forKey: key)
        return image
    }

    private func stampKey(width: Int, height: Int) -> NSString {
        "\(width)x\(height)|\(settings.enabled)|\(settings.text)|\(settings.useLogo)|\(settings.logoPath ?? "")|\(settings.position.rawValue)|\(settings.opacity)|\(settings.sizeFraction)|\(settings.tiled)|\(settings.tileSpacing)" as NSString
    }

    private static let cache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 24
        return cache
    }()
}
