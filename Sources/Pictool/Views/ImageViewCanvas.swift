import SwiftUI
import AppKit
import ImageIO

/// 主视图画布:NSScrollView + NSImageView(AppKit 混合核心点)。
/// 触控板捏合 / ⌘ 或 ⌥ + 滚轮缩放(以光标为锚点),拖拽平移,双击切换 适配/实际大小。
/// 浏览时按窗口 2 倍降采样解码;放大越过阈值自动加载全尺寸替换(视觉无缝)。
struct ImageViewCanvas: NSViewRepresentable {

    let file: ImageFile?
    let neighborURLs: [URL]
    let zoomRequest: (action: ZoomAction, token: Int)?
    let rotateRequestToken: Int
    /// 切图方向信号:+1 向后翻(新图从右滑入),-1 向前,0 无方向(淡入)
    let stepDirection: Int
    var onLoadingChange: (Bool) -> Void
    var onScaleChange: (CGFloat) -> Void
    var onImageInfo: (DisplayImageInfo) -> Void
    var onStep: (Int) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        context.coordinator.scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        coordinator.applyFile(file)
        if let request = zoomRequest, request.token != coordinator.appliedZoomToken {
            coordinator.appliedZoomToken = request.token
            coordinator.performZoom(request.action)
        }
        if rotateRequestToken != coordinator.appliedRotateToken {
            coordinator.appliedRotateToken = rotateRequestToken
            coordinator.performRotate()
        }
    }

    // MARK: - Coordinator

    @MainActor
    final class Coordinator {

        var parent: ImageViewCanvas
        let scrollView = CanvasScrollView()
        let clipView = CanvasClipView()
        let imageView = CanvasImageView()

        private(set) var currentURL: URL?
        private var loadTask: Task<Void, Never>?
        private var animationTask: Task<Void, Never>?
        var appliedZoomToken = 0
        var appliedRotateToken = 0
        private let zoomDebug = ProcessInfo.processInfo.arguments.contains("--zoom-debug")

        private func debugLog(_ tag: String) {
            guard zoomDebug else { return }
            let b = clipView.bounds
            print("[zoom] \(tag) scale=\(scale) fitScale=\(fitScale) wasFit=\(wasFit) origin=(\(b.origin.x), \(b.origin.y)) frame=\(imageView.frame) clip=(\(b.width), \(b.height)) mag=\(scrollView.magnification)")
            fflush(stdout)
        }

        /// 延迟复查:捕获"事后被改回"的延迟性回退
        private func lateCheck(_ tag: String, after: TimeInterval = 0.6) {
            DispatchQueue.main.asyncAfter(deadline: .now() + after) { [weak self] in
                self?.debugLog("LATE[\(tag)]")
            }
        }

        private var scale: CGFloat = 1          // 点 / 图像点(以当前 NSImage.size 为准)
        private var fitScale: CGFloat = 1
        private var wasFit = true
        private var isFullResolution = false
        private var escalating = false
        private var truePixelSize = CGSize.zero
        /// 当前 imageView 位图的真实像素(旋转后宽高对调;动图帧始终等于 truePixelSize)。
        /// 缩放读数与升级解码判定的统一几何基准。
        private var bitmapPixelSize = CGSize.zero
        /// 位图已被用户旋转过(此时不再从降采样缓存升级,避免旋转被覆盖)
        private var isRotatedBitmap = false
        private var mutatingCanvas = false
        private var lastNotifiedPercent = Int.min
        private var escalateWork: DispatchWorkItem?

        init(_ parent: ImageViewCanvas) {
            self.parent = parent

            scrollView.hasVerticalScroller = true
            scrollView.hasHorizontalScroller = true
            scrollView.autohidesScrollers = true
            // overlay 不挤占 contentView,避免缩放越过视口时滚动条弹出导致取景跳一下
            scrollView.scrollerStyle = .overlay
            scrollView.automaticallyAdjustsContentInsets = false
            scrollView.contentInsets = NSEdgeInsets()
            scrollView.borderType = .noBorder
            scrollView.drawsBackground = true
            scrollView.backgroundColor = NSColor(white: 0.10, alpha: 1)
            // 捏合不走系统 magnification(手势结束兑换 frame 必有一次跳变),与滚轮同一套 applyScale
            scrollView.allowsMagnification = false
            clipView.documentView = imageView
            scrollView.contentView = clipView

            imageView.imageScaling = .scaleNone

            clipView.onZoomDelta = { [weak self] delta, anchor in
                self?.smoothZoom(multiplyingBy: 1 + delta, anchor: anchor, duration: 0.18)
            }
            scrollView.onMagnifyDelta = { [weak self] delta, anchor in
                // 捏合跟手要短,否则会拖在手指后面
                self?.smoothZoom(multiplyingBy: 1 + delta, anchor: anchor, duration: 0.08)
            }
            scrollView.onSmartZoom = { [weak self] in
                guard let self else { return }
                self.toggleZoom(at: self.visibleCenter())
            }
            clipView.onStep = { [weak self] delta in
                self?.parent.onStep(delta)
            }
            clipView.onHorizontalSwipe = { [weak self] direction in
                self?.parent.onStep(direction > 0 ? 1 : -1)
            }
            clipView.onLayoutChange = { [weak self] in
                self?.handleLayout()
            }
            clipView.onSmartZoom = { [weak self] in
                guard let self else { return }
                self.toggleZoom(at: self.visibleCenter())
            }
            imageView.onDoubleClick = { [weak self] in
                guard let self else { return }
                self.toggleZoom(at: self.visibleCenter())
            }
            imageView.onPan = { [weak self] delta in
                self?.pan(by: delta)
            }
            imageView.onSwipe = { [weak self] delta in
                self?.parent.onStep(delta)
            }

            setupSelfTestHooks()
        }

        /// 捏合手势结束:立即把视觉缩放(magnification)兑换为真实重绘。
        /// 若长期保留 magnification≠1,布局处理、缩放下限、升级解码都会基于失真状态运算,
        /// 且双击适配等路径不会重置它导致显示尺寸错误。
        private func finishLiveMagnification() {
            guard imageView.image != nil else { return }
            debugLog("liveMagnify end m=\(scrollView.magnification)")
            if abs(scrollView.magnification - 1) > 0.0005 {
                absorbMagnification()
                lateCheck("afterAbsorb")
            }
        }

        /// 把当前的视觉缩放(magnification)在同一帧内兑换为真实重绘。
        /// AppKit 内建放大以视口中心为锚(实测 magnification 前后文档中心不变),
        /// 兑换也必须全程中心锚定:先归一(视觉回到手势前取景),再绕同一中心放大内容。
        /// 若改用光标锚定会与系统语义错位,兑换瞬间产生方向性漂移。
        /// 只在无手势进行时调用(按钮/键盘/手势结束),手势进行中禁止。
        private func absorbMagnification() {
            guard imageView.image != nil else { return }
            let m = scrollView.magnification
            guard abs(m - 1) > 0.0005 else {
                scrollView.magnification = 1
                return
            }
            debugLog("absorb m=\(m)")
            wasFit = false
            applyScale(scale * m, anchor: visibleCenter(), resetMagnification: true)
        }

        /// 自测:模拟一次捏合结束
        private func setupSelfTestHooks() {
            guard ProcessInfo.processInfo.arguments.contains("--zoom-test") else { return }
            NotificationCenter.default.addObserver(
                forName: Notification.Name("PictoolSimPinch"), object: nil, queue: .main
            ) { [weak self] note in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    let m = (note.userInfo?["m"] as? Double) ?? 1.5
                    self.debugLog("SIM pinch begin m=\(m)")
                    self.scrollView.magnification = CGFloat(m)
                    self.finishLiveMagnification()
                    self.lateCheck("afterSimPinch")
                }
            }
        }

        // MARK: 加载

        func applyFile(_ file: ImageFile?) {
            let url = file?.url
            guard url != currentURL else { return }
            currentURL = url
            stopAnimation()
            cancelSmoothZoom()
            loadTask?.cancel()
            escalateWork?.cancel()
            escalating = false
            scrollView.magnification = 1   // 切换图片时重置手势缩放

            guard let url else {
                imageView.image = nil
                parent.onLoadingChange(false)
                parent.onImageInfo(DisplayImageInfo())
                parent.onScaleChange(1)
                return
            }

            let maxPixel = displayMaxPixel()
            if let cached = ImageLoader.cachedDisplayImage(url: url, maxPixelSize: maxPixel) {
                parent.onLoadingChange(false)
                setDisplayImage(cached.image, facts: cached.facts, url: url)
                runEntryTransition(direction: parent.stepDirection)
                prefetchNeighbors(maxPixel: maxPixel)
                return
            }

            // 保留上一张直到新图就绪,避免切图闪白。连按方向键时短延迟合并,避免中间图全部开解。
            parent.onLoadingChange(true)
            loadTask = Task { [weak self] in
                guard let self else { return }
                try? await Task.sleep(nanoseconds: 50_000_000)
                guard !Task.isCancelled, self.currentURL == url else { return }
                let loaded = await ImageLoader.displayImage(url: url, maxPixelSize: maxPixel)
                guard !Task.isCancelled, self.currentURL == url else { return }
                self.parent.onLoadingChange(false)
                if let loaded {
                    self.setDisplayImage(loaded.image, facts: loaded.facts, url: url)
                    self.runEntryTransition(direction: self.parent.stepDirection)
                } else {
                    self.imageView.image = nil
                    self.parent.onImageInfo(DisplayImageInfo())
                }
                self.prefetchNeighbors(maxPixel: maxPixel)
            }
        }

        /// 切图入场过渡:新图沿切换方向轻微滑入并淡入(0.25s ease-out),平缓不抢眼。
        /// 只动图层几何与透明度,GPU 合成,无额外解码。
        private func runEntryTransition(direction: Int) {
            guard let layer = imageView.layer, imageView.image != nil else { return }
            CATransaction.begin()
            CATransaction.setDisableActions(false)
            layer.removeAnimation(forKey: "entrySlide")
            if direction != 0 {
                // 从切换方向滑入 24pt + 淡入
                let slide = CABasicAnimation(keyPath: "position.x")
                slide.fromValue = layer.position.x - CGFloat(direction) * 24
                slide.toValue = layer.position.x
                slide.duration = 0.25
                slide.timingFunction = CAMediaTimingFunction(name: .easeOut)
                layer.add(slide, forKey: "entrySlide")

                let fade = CABasicAnimation(keyPath: "opacity")
                fade.fromValue = 0.0
                fade.toValue = 1.0
                fade.duration = 0.22
                fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
                layer.add(fade, forKey: "entryFade")
            } else {
                let fade = CABasicAnimation(keyPath: "opacity")
                fade.fromValue = 0.0
                fade.toValue = 1.0
                fade.duration = 0.18
                fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
                layer.add(fade, forKey: "entryFade")
            }
            CATransaction.commit()
        }

        private func prefetchNeighbors(maxPixel: CGFloat) {
            let urls = parent.neighborURLs
            guard !urls.isEmpty else { return }
            for url in urls {
                ImageLoader.prefetchDisplay(url: url, maxPixelSize: maxPixel)
            }
        }

        private func displayMaxPixel() -> CGFloat {
            let size = clipView.bounds.size
            return max(2048, CGFloat(Int(max(size.width, size.height))) * 2)
        }

        private func setDisplayImage(_ image: NSImage?, facts: ImageLoader.SourceFacts, url: URL) {
            parent.onLoadingChange(false)
            isFullResolution = false
            guard let image, facts.pixelWidth > 0 else {
                imageView.image = nil
                parent.onImageInfo(DisplayImageInfo())
                return
            }
            truePixelSize = CGSize(width: facts.pixelWidth, height: facts.pixelHeight)
            bitmapPixelSize = truePixelSize
            isRotatedBitmap = false
            parent.onImageInfo(DisplayImageInfo(
                pixelWidth: facts.pixelWidth,
                pixelHeight: facts.pixelHeight,
                frameCount: facts.frameCount,
                formatName: MetadataService.formatName(of: facts.formatID)
            ))
            imageView.image = image
            applyFit()
            if facts.frameCount > 1 {
                startAnimation(url: url)
            }
        }

        // MARK: 动图(GIF / APNG)

        /// 动画代数:切换图片时递增,使旧动画的帧回调失效
        private final class AnimationState: @unchecked Sendable {
            private let lock = NSLock()
            private var generation = 0
            @discardableResult
            func advance() -> Int {
                lock.lock(); defer { lock.unlock() }
                generation += 1
                return generation
            }
            func isCurrent(_ gen: Int) -> Bool {
                lock.lock(); defer { lock.unlock() }
                return gen == generation
            }
        }

        private let animState = AnimationState()

        /// CLT SDK 提供 block 版本 API:block 在主队列按帧回调,stop 指针停止播放
        private func startAnimation(url: URL) {
            let generation = animState.advance()
            let displaySize = imageView.image?.size ?? .zero
            animationTask = Task.detached(priority: .userInitiated) { [weak self] in
                guard let self else { return }
                let state = self.animState
                CGAnimateImageAtURLWithBlock(url as CFURL, nil as CFDictionary?) { _, frame, stop in
                    guard state.isCurrent(generation) else {
                        stop.pointee = true
                        return
                    }
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        guard self.currentURL == url else {
                            self.animState.advance()
                            return
                        }
                        let size = displaySize.width > 0
                            ? displaySize
                            : NSSize(width: frame.width, height: frame.height)
                        self.imageView.image = NSImage(cgImage: frame, size: size)
                    }
                }
            }
        }

        private func stopAnimation() {
            animState.advance()
            animationTask?.cancel()
            animationTask = nil
        }

        // MARK: 布局与缩放

        private var imageSize: CGSize {
            imageView.image?.size ?? .zero
        }

        private func handleLayout() {
            guard !mutatingCanvas, imageView.image != nil else { return }
            // 捏合手势进行中(bounds 尺寸被 magnification 改变),不干预布局
            guard abs(scrollView.magnification - 1) < 0.001 else { return }
            let newFit = fitScaleValue()
            guard abs(newFit - fitScale) > 0.001 else { return }
            debugLog("handleLayout fitChange \(fitScale) -> \(newFit) wasFit=\(wasFit)")
            fitScale = newFit
            if wasFit {
                applyFit()
            } else if scale < minScale {
                applyScale(minScale, anchor: visibleCenter())
            }
        }

        private func fitScaleValue() -> CGFloat {
            guard imageSize.width > 0, imageSize.height > 0 else { return 1 }
            let clip = clipView.bounds.size
            guard clip.width > 0, clip.height > 0 else { return 1 }
            return min(clip.width / imageSize.width, clip.height / imageSize.height)
        }

        private func applyFit() {
            // 防御:任何残留的手势缩放都会叠加在适配结果上,先归一
            if abs(scrollView.magnification - 1) > 0.0005 { scrollView.magnification = 1 }
            fitScale = fitScaleValue()
            scale = fitScale
            wasFit = true
            updateFrameCentered()
            notifyScale()
        }

        private func updateFrameCentered() {
            guard imageSize.width > 0 else { return }
            let size = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
            let origin = ZoomMath.constrainedOrigin(
                proposed: .zero,
                docSize: size,
                clipSize: clipView.bounds.size
            )
            commitCanvasChange {
                applyDocument(size: size, origin: origin, snap: true)
            }
        }

        func performZoom(_ action: ZoomAction) {
            debugLog("performZoom \(action) begin")
            guard imageView.image != nil else { return }
            defer { lateCheck("afterZoom\(action == .fit ? "Fit" : action == .actualSize ? "Actual" : action == .zoomIn ? "In" : "Out")") }
            switch action {
            case .fit:
                absorbMagnification()
                startSmoothZoom(to: fitScaleValue(), anchor: visibleCenter(),
                                duration: 0.22, completesAsFit: true)
            case .actualSize:
                absorbMagnification()
                if isFullResolution {
                    setAbsoluteActualSize()
                } else {
                    escalate { [weak self] in
                        self?.setAbsoluteActualSize()
                    }
                }
            case .zoomIn:
                absorbMagnification()
                smoothZoom(multiplyingBy: 1.25, anchor: visibleCenter(), duration: 0.22)
            case .zoomOut:
                absorbMagnification()
                smoothZoom(multiplyingBy: 0.8, anchor: visibleCenter(), duration: 0.22)
            }
        }

        /// 可视区域中心(clip 视图本地坐标)
        private func visibleCenter() -> CGPoint {
            CGPoint(x: clipView.bounds.width / 2, y: clipView.bounds.height / 2)
        }

        /// 缩放下限:允许缩小到适配档的 1/10(小图在"适配"时是放大态,也允许继续缩小)
        private var minScale: CGFloat {
            min(fitScale, 1) * 0.1
        }

        /// 实际大小:1 图像像素 = 1 屏幕物理像素
        private func setAbsoluteActualSize() {
            let backing = scrollView.window?.backingScaleFactor ?? 2
            startSmoothZoom(to: 1 / backing, anchor: visibleCenter(), duration: 0.22)
        }

        private func toggleZoom(at location: CGPoint) {
            guard imageView.image != nil else { return }
            let backing = scrollView.window?.backingScaleFactor ?? 2
            let effective = effectiveScale(backing: backing)
            if wasFit || effective < 0.35 {
                performZoom(.actualSize)
            } else {
                applyFit()
            }
        }

        // MARK: 平滑缩放(显示链路按时长缓出)

        private var zoomLink: CADisplayLink?
        private var zoomTarget: CGFloat?
        private var zoomStart: CGFloat = 1
        private var zoomStartTime: CFTimeInterval = 0
        private var zoomDuration: CFTimeInterval = 0.22
        private var zoomAnchorPoint: CGPoint = .zero
        private var zoomCompletesAsFit = false

        /// 滚轮 / 按钮 / 捏合:目标倍率累积,按剩余时长缓出,连点是一次连贯运动。
        private func smoothZoom(multiplyingBy factor: CGFloat, anchor: CGPoint?, duration: CFTimeInterval) {
            guard imageView.image != nil else { return }
            wasFit = false
            let b = clipView.bounds
            var pt = anchor ?? visibleCenter()
            pt.x = min(max(pt.x, b.minX), b.maxX)
            pt.y = min(max(pt.y, b.minY), b.maxY)
            let base = zoomTarget ?? scale
            startSmoothZoom(to: base * factor, anchor: pt, duration: duration)
        }

        private func startSmoothZoom(to targetRaw: CGFloat, anchor: CGPoint,
                                     duration: CFTimeInterval, completesAsFit: Bool = false) {
            let target = min(max(targetRaw, minScale), 64)
            guard abs(target - scale) > 0.0005 else {
                if completesAsFit { applyFit() }
                cancelSmoothZoom()
                return
            }
            zoomAnchorPoint = anchor
            zoomTarget = target
            zoomStart = scale
            zoomDuration = max(duration, 0.04)
            zoomStartTime = CACurrentMediaTime()
            zoomCompletesAsFit = completesAsFit
            wasFit = false
            startZoomLinkIfNeeded()
        }

        private func startZoomLinkIfNeeded() {
            guard zoomLink == nil else { return }
            let proxy = ZoomTickProxy()
            proxy.coordinator = self
            let link = imageView.displayLink(target: proxy,
                                             selector: #selector(ZoomTickProxy.tick(_:)))
            proxy.link = link
            link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
            link.add(to: .main, forMode: .common)
            zoomLink = link
        }

        private func cancelSmoothZoom() {
            zoomLink?.invalidate()
            zoomLink = nil
            zoomTarget = nil
            zoomCompletesAsFit = false
        }

        func zoomTick() {
            guard imageView.image != nil, let target = zoomTarget else {
                cancelSmoothZoom()
                return
            }
            let t = min(1, (CACurrentMediaTime() - zoomStartTime) / zoomDuration)
            // ease-out cubic: 起手干脆,收尾不硬切
            let eased = 1 - pow(1 - t, 3)
            let next = zoomStart + (target - zoomStart) * CGFloat(eased)
            if t >= 1 {
                let asFit = zoomCompletesAsFit
                applyScale(target, anchor: zoomAnchorPoint, settling: true)
                cancelSmoothZoom()
                if asFit { wasFit = true }
            } else {
                applyScale(next, anchor: zoomAnchorPoint, settling: false)
            }
        }

        /// 弱引用代理:NSView.displayLink 强持有 target,直接传 self 会形成保留环
        @MainActor
        private final class ZoomTickProxy: NSObject {
            weak var coordinator: Coordinator?
            weak var link: CADisplayLink?
            @objc func tick(_ sender: CADisplayLink) {
                guard let coordinator else {
                    link?.invalidate()
                    return
                }
                coordinator.zoomTick()
            }
        }

        private func commitCanvasChange(_ body: () -> Void) {
            mutatingCanvas = true
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            body()
            CATransaction.commit()
            clipView.pinnedOrigin = nil
            mutatingCanvas = false
        }

        /// 写入文档尺寸与取景。动画过程不对齐像素(避免逐帧台阶),停稳后再贴 backing。
        private func applyDocument(size: CGSize, origin: NSPoint, snap: Bool) {
            let backing = scrollView.window?.backingScaleFactor ?? 2
            let outSize = snap
                ? CGSize(width: ZoomMath.snapped(size.width, backing: backing),
                         height: ZoomMath.snapped(size.height, backing: backing))
                : size
            let outOrigin = snap ? ZoomMath.snappedPoint(origin, backing: backing) : origin
            clipView.pinnedOrigin = outOrigin
            imageView.frame = NSRect(origin: .zero, size: outSize)
            clipView.setBoundsOrigin(outOrigin)
            scrollView.reflectScrolledClipView(clipView)
        }

        /// 核心缩放:内容随 frame 伸缩,锚点(本地坐标)指向的内容点保持不动
        private func applyScale(_ newScale: CGFloat, anchor: CGPoint,
                                resetMagnification: Bool = false, settling: Bool = true) {
            guard imageView.image != nil, imageSize.width > 0, scale > 0 else { return }
            let clamped = min(max(newScale, minScale), 64)
            guard clamped != scale || resetMagnification else {
                debugLog("applyScale SKIPPED clamped==scale")
                return
            }
            debugLog("applyScale from=\(scale) to=\(clamped) anchor=(\(anchor.x), \(anchor.y))")
            commitCanvasChange {
                if resetMagnification { scrollView.magnification = 1 }
                let oldDoc = imageView.frame.size.width > 0
                    ? imageView.frame.size
                    : CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
                let newSize = CGSize(width: imageSize.width * clamped, height: imageSize.height * clamped)
                let ratio = oldDoc.width > 0 ? newSize.width / oldDoc.width : 1
                let zoomAnchor = resetMagnification ? visibleCenter() : anchor
                let anchored = ZoomMath.anchoredOrigin(
                    oldOrigin: clipView.bounds.origin,
                    anchor: zoomAnchor,
                    docSize: oldDoc,
                    ratio: ratio
                )
                let origin = ZoomMath.constrainedOrigin(
                    proposed: anchored,
                    docSize: newSize,
                    clipSize: clipView.bounds.size
                )
                applyDocument(size: newSize, origin: origin, snap: settling)
                if settling, imageSize.width > 0 {
                    scale = imageView.frame.width / imageSize.width
                } else {
                    scale = clamped
                }
            }
            debugLog("applyScale done")
            notifyScale()
            if settling {
                scheduleEscalateCheck()
            }
        }

        /// 百分比语义:每个图像源像素对应多少屏幕物理像素。
        /// 由几何直接推导(frame 点数 × backing ÷ 当前位图像素宽),
        /// 与当前加载的表示(降采样或全尺寸)无关——否则大图降采样浏览时读数偏低,
        /// 且升级到全尺寸瞬间同一画面会跳变。DPI 标注的文件按真实像素如实呈现。
        private func effectiveScale(backing: CGFloat) -> CGFloat {
            let frameWidth = imageView.frame.width
            if frameWidth > 0, bitmapPixelSize.width > 0 {
                return frameWidth * backing * scrollView.magnification / bitmapPixelSize.width
            }
            return scale * scrollView.magnification
        }

        private func notifyScale() {
            let backing = scrollView.window?.backingScaleFactor ?? 2
            let value = effectiveScale(backing: backing)
            let percent = Int((value * 100).rounded())
            guard percent != lastNotifiedPercent else { return }
            lastNotifiedPercent = percent
            debugLog("notify percent=\(percent)% frameW=\(imageView.frame.width) trueW=\(truePixelSize.width)")
            parent.onScaleChange(value)
        }

        /// 等平滑缩放停稳再升级,避免解码完成时叠在动画尾帧上造成一次位移
        private func scheduleEscalateCheck() {
            escalateWork?.cancel()
            let work = DispatchWorkItem { [weak self] in
                self?.maybeEscalate()
            }
            escalateWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
        }

        /// 缩放后如果当前表示的像素不足以清晰呈现,加载全尺寸替换(视觉尺寸保持不变)
        private func maybeEscalate() {
            guard !isFullResolution, !escalating, !isRotatedBitmap, zoomTarget == nil,
                  let image = imageView.image,
                  let rep = image.representations.first, rep.pixelsWide > 0 else { return }
            let backing = scrollView.window?.backingScaleFactor ?? 2
            let displayedPx = imageView.frame.width * backing
            if displayedPx > bitmapPixelSize.width * 1.05 {
                escalate {}
            }
        }

        private func escalate(completion: @escaping () -> Void) {
            guard let url = currentURL, !escalating else {
                completion()
                return
            }
            escalating = true
            Task { [weak self] in
                guard let self else { return }
                let full: NSImage? = await Task.detached(priority: .userInitiated) {
                    try? ImageLoader.decode(url: url, maxPixelSize: nil)
                }.value
                defer {
                    self.escalating = false
                    completion()
                }
                guard !Task.isCancelled, self.currentURL == url, let full,
                      full.size.width > 0 else { return }
                // 以解码完成时的实时视觉尺寸换算:
                // 加载期间用户的缩放/平移不能被解码开始前的快照覆盖(延迟回跳的根源)
                let visual = self.imageView.frame.size
                let origin = self.clipView.bounds.origin
                guard visual.width > 0 else { return }
                let newScale = min(max(visual.width / full.size.width, self.minScale), 64)
                let newSize = CGSize(width: full.size.width * newScale, height: full.size.height * newScale)
                let kept = ZoomMath.originKeepingVisibleCenter(
                    oldOrigin: origin,
                    oldDoc: visual,
                    newDoc: newSize,
                    clipSize: self.clipView.bounds.size
                )
                self.commitCanvasChange {
                    self.imageView.image = full
                    self.bitmapPixelSize = CGSize(
                        width: full.representations.first?.pixelsWide ?? Int(full.size.width),
                        height: full.representations.first?.pixelsHigh ?? Int(full.size.height)
                    )
                    self.isFullResolution = true
                    self.scale = newScale
                    self.applyDocument(size: newSize, origin: kept, snap: true)
                    self.fitScale = self.fitScaleValue()
                }
                self.notifyScale()
            }
        }

        private func pan(by delta: CGSize) {
            guard imageView.image != nil else { return }
            wasFit = false
            let proposed = NSPoint(
                x: clipView.bounds.origin.x - delta.width,
                y: clipView.bounds.origin.y - delta.height
            )
            let origin = ZoomMath.constrainedOrigin(
                proposed: proposed,
                docSize: imageView.frame.size,
                clipSize: clipView.bounds.size
            )
            commitCanvasChange {
                applyDocument(size: imageView.frame.size, origin: origin, snap: true)
            }
        }

        // MARK: 旋转

        /// 顺时针旋转 90°(可叠加):直接旋转位图后替换 image。
        /// 替换后宽高已对调,bitmapPixelSize 同步翻转,缩放读数/升级判定保持正确。
        func performRotate() {
            guard imageView.image != nil,
                  let cg = imageView.image?.cgImage(forProposedRect: nil, context: nil, hints: nil),
                  let rotated = ImageLoader.rotatedCW90(cg) else { return }
            cancelSmoothZoom()
            absorbMagnification()
            // 动图每帧会用原始帧重建 NSImage,会覆盖旋转结果;先停播再转(静态呈现当前帧的旋转变体)
            stopAnimation()
            let newImage = NSImage(cgImage: rotated, size: NSSize(width: cg.height, height: cg.width))
            commitCanvasChange {
                self.imageView.image = newImage
                self.bitmapPixelSize = CGSize(width: cg.height, height: cg.width)
                self.isRotatedBitmap = true   // 位图已重排:不再升级解码(会覆盖旋转),读数以位图为准
                self.isFullResolution = true
                self.applyFit()
            }
        }
    }
}

// MARK: - AppKit 子类

/// 捏合手势自己处理,避免 NSScrollView.magnification 在松手时再兑换一次 frame。
final class CanvasScrollView: NSScrollView {
    var onMagnifyDelta: ((CGFloat, CGPoint) -> Void)?
    var onSmartZoom: (() -> Void)?

    override func magnify(with event: NSEvent) {
        let loc = contentView.convert(event.locationInWindow, from: nil)
        onMagnifyDelta?(event.magnification, loc)
    }

    override func smartMagnify(with event: NSEvent) {
        onSmartZoom?()
    }
}

/// 居中裁剪视图:文档小于可视区时居中。
/// ⌘/⌥ 滚轮缩放与左右方向键由本类处理。
final class CanvasClipView: NSClipView {

    var onZoomDelta: ((CGFloat, CGPoint) -> Void)?
    var onStep: ((Int) -> Void)?
    var onLayoutChange: (() -> Void)?
    var onSmartZoom: (() -> Void)?
    /// 触控板双指横滑切图(仅图片水平方向无溢出时启用)
    var onHorizontalSwipe: ((CGFloat) -> Void)?
    /// applyDocument 写入期间锁定 origin,防止 constrain 在同一拍改掉取景
    var pinnedOrigin: NSPoint?

    private var swipeAccumulatedDX: CGFloat = 0
    private var swipeGestureActive = false
    private var swipeCommittedThisGesture = false
    /// 提交防抖:两次提交至少间隔此秒数,兜住异常事件流(如未发 .ended 的手势)
    private var lastSwipeCommitTime = TimeInterval(0)
    private static let horizontalSwipeThreshold: CGFloat = 55
    private static let swipeCommitMinInterval: TimeInterval = 0.30

    override func draw(_ dirtyRect: NSRect) {
        NSColor(white: 0.10, alpha: 1).setFill()
        dirtyRect.fill()
    }

    override func scrollWheel(with event: NSEvent) {
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if mods.contains(.command) || mods.contains(.option) {
            // 以光标为锚点缩放(与捏合语义一致)
            onZoomDelta?(event.scrollingDeltaY * 0.01, convert(event.locationInWindow, from: nil))
            return
        }
        // 触控板双指横滑(|dx| 明显大于 |dy|)且文档横向不可滚动 → 切图手势;
        // 其余(纵向滚动、惯性余量)交给系统滚动。
        let dx = event.scrollingDeltaX
        let dy = event.scrollingDeltaY
        if abs(dx) > abs(dy) * 2, abs(dx) > 0.5,
           !isDocumentHorizontallyScrollable,
           event.phase != .ended, event.momentumPhase == [] {
            swipeGestureActive = true
            swipeAccumulatedDX += dx   // 自然滚动:内容左移(dx>0)= 看下一张
            // 一个手势只提交一张 + 两次提交至少隔 0.3s,双保险防长滑连切
            let now = CACurrentMediaTime()
            if !swipeCommittedThisGesture,
               now - lastSwipeCommitTime >= Self.swipeCommitMinInterval,
               abs(swipeAccumulatedDX) >= Self.horizontalSwipeThreshold {
                onHorizontalSwipe?(swipeAccumulatedDX > 0 ? 1 : -1)
                swipeCommittedThisGesture = true
                lastSwipeCommitTime = now
                swipeAccumulatedDX = 0
            }
            return
        }
        if event.phase == .ended || (swipeGestureActive && event.momentumPhase != []) {
            // 手势收尾/进入惯性:清账并解锁,不把残余位移误当新手势
            swipeGestureActive = false
            swipeCommittedThisGesture = false
            swipeAccumulatedDX = 0
            if event.momentumPhase != [] { return }
        }
        super.scrollWheel(with: event)
    }

    private var isDocumentHorizontallyScrollable: Bool {
        guard let doc = documentView else { return false }
        return doc.frame.width > bounds.width + 0.5
    }

    override func magnify(with event: NSEvent) {
        enclosingScrollView?.magnify(with: event)
    }

    override func smartMagnify(with event: NSEvent) {
        onSmartZoom?()
    }

    override func moveLeft(_ sender: Any?) { onStep?(-1) }
    override func moveRight(_ sender: Any?) { onStep?(1) }

    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var rect = proposedBounds
        if let pinned = pinnedOrigin {
            rect.origin = pinned
            return rect
        }
        guard let doc = documentView?.frame else { return super.constrainBoundsRect(proposedBounds) }
        let backing = window?.backingScaleFactor ?? 2
        rect.origin = ZoomMath.snappedPoint(
            ZoomMath.constrainedOrigin(
                proposed: proposedBounds.origin,
                docSize: doc.size,
                clipSize: proposedBounds.size
            ),
            backing: backing
        )
        return rect
    }

    override func layout() {
        super.layout()
        onLayoutChange?()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, let window = self.window else { return }
            if let responder = window.firstResponder, responder is NSTextView { return }
            window.makeFirstResponder(self)
        }
    }
}

/// 图片视图:双击切换缩放;鼠标拖拽按手势模式分流——
/// 图片水平方向无溢出时,横向主导的拖动是「滑动切图」(阈值提交,防误触);
/// 其余情况走平移。渲染走 layer.contents(GPU 纹理):缩放改 frame 只是几何变换,
/// 不触发主线程按新尺寸重栅格化位图——丝滑的关键。
final class CanvasImageView: NSImageView {

    var onDoubleClick: (() -> Void)?
    var onPan: ((CGSize) -> Void)?
    /// 滑动切图提交:>0 右划(上一张),<0 左划(下一张);仅越阈值时回调
    var onSwipe: ((Int) -> Void)?

    private enum DragMode { case undecided, pan, swipe }
    private var dragMode: DragMode = .undecided
    private var mouseDownPoint: NSPoint?
    private var lastDragPoint: NSPoint?
    private var swipeTotalDX: CGFloat = 0
    private static let swipeDecideThreshold: CGFloat = 10
    private static let swipeCommitThreshold: CGFloat = 60

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        commonInit()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }

    private func commonInit() {
        // 层托管(layer-hosting):自建 CALayer 并接管,
        // AppKit 不再向层栅格化 draw(_) 内容,layer.contents 由本类独占管理
        wantsLayer = true
        let hostLayer = CALayer()
        hostLayer.contentsGravity = .resize
        hostLayer.minificationFilter = .trilinear
        // 禁止 frame/contents 隐式动画,否则缩放停住后图层还会再滑一小段
        hostLayer.actions = [
            "bounds": NSNull(),
            "position": NSNull(),
            "contents": NSNull(),
            "contentsScale": NSNull(),
            "transform": NSNull(),
        ]
        layer = hostLayer
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        syncLayer()
    }

    override var image: NSImage? {
        get { super.image }
        set {
            let kept = frame
            super.image = newValue
            if frame != kept { frame = kept }
            syncLayer()
        }
    }

    private func syncLayer() {
        guard let layer else { return }
        layer.contentsScale = window?.backingScaleFactor ?? 2
        layer.contents = image?.cgImage(forProposedRect: nil, context: nil, hints: nil)
    }

    /// 内容由 GPU 纹理呈现;AppKit 位图绘制通道关闭
    override func draw(_ dirtyRect: NSRect) {}

    override func magnify(with event: NSEvent) {
        enclosingScrollView?.magnify(with: event)
    }

    override func smartMagnify(with event: NSEvent) {
        enclosingScrollView?.smartMagnify(with: event)
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            resetDragState()
            onDoubleClick?()
            return
        }
        dragMode = .undecided
        mouseDownPoint = convert(event.locationInWindow, from: nil)
        lastDragPoint = mouseDownPoint
        swipeTotalDX = 0
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = mouseDownPoint, let last = lastDragPoint else { return }
        let current = convert(event.locationInWindow, from: nil)
        let total = CGSize(width: current.x - start.x, height: current.y - start.y)

        if dragMode == .undecided {
            let absX = abs(total.width), absY = abs(total.height)
            guard max(absX, absY) >= Self.swipeDecideThreshold else { return }
            // 横向主导且图片水平方向没有可滚动余量 → 滑动切图;其余一律平移
            if absX > absY && !isHorizontallyOverflowing {
                dragMode = .swipe
            } else {
                dragMode = .pan
            }
        }
        switch dragMode {
        case .swipe:
            swipeTotalDX += current.x - last.x
        case .pan:
            onPan?(CGSize(width: current.x - last.x, height: current.y - last.y))
        case .undecided:
            break
        }
        lastDragPoint = current
    }

    override func mouseUp(with event: NSEvent) {
        defer { resetDragState() }
        guard dragMode == .swipe, abs(swipeTotalDX) >= Self.swipeCommitThreshold else { return }
        // 向右拖(dx>0)= 看上一张;向左拖 = 看下一张
        onSwipe?(swipeTotalDX > 0 ? -1 : 1)
    }

    private func resetDragState() {
        dragMode = .undecided
        mouseDownPoint = nil
        lastDragPoint = nil
        swipeTotalDX = 0
    }

    /// 图片显示宽度是否超过视口宽度(超出时横向拖动属于平移语义)
    private var isHorizontallyOverflowing: Bool {
        guard let clip = enclosingScrollView?.contentView else { return false }
        return frame.width > clip.bounds.width + 0.5
    }
}
