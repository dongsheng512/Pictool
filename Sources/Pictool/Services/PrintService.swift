import AppKit

@MainActor
enum PrintService {

    /// 标准打印面板:视图按图片点尺寸排版,缩放百分比由 AppKit 作用到预览。
    /// 100% = 原图 72dpi 实际大小;打开时把百分比设为「刚好铺满当前纸张」,之后拖动即按正常百分比缩放。
    static func print(image: NSImage) {
        let info = NSPrintInfo.shared.copy() as! NSPrintInfo
        info.horizontalPagination = .clip
        info.verticalPagination = .clip
        info.isVerticallyCentered = true
        info.isHorizontallyCentered = true
        // 原生缩放本身不要求留白。边距 0,初始百分比按整张纸计算,避免「可印区域」
        // (打印机硬件边 + 默认 1 英寸页边)把图缩在纸心。
        info.leftMargin = 0
        info.rightMargin = 0
        info.topMargin = 0
        info.bottomMargin = 0

        let imgSize = PrintPageView.imageAspect(image)
        if imgSize.width > 0, imgSize.height > 0 {
            info.orientation = imgSize.width >= imgSize.height ? .landscape : .portrait
        }

        info.scalingFactor = PrintPageView.fitScale(imageSize: imgSize, paperSize: info.paperSize)

        let view = PrintPageView(image: image)
        let operation = NSPrintOperation(view: view, printInfo: info)
        operation.canSpawnSeparateThread = false
        operation.printPanel.options.insert([.showsOrientation, .showsScaling])
        if let window = NSApp.keyWindow ?? NSApp.mainWindow {
            operation.runModal(for: window, delegate: nil, didRun: nil, contextInfo: nil)
        }
    }
}

/// 文档就是图片本身。分页/缩放交给 NSPrintOperation,预览才能跟着百分比走。
final class PrintPageView: NSView {

    private let image: NSImage

    init(image: NSImage) {
        self.image = image
        let size = Self.imageAspect(image)
        super.init(frame: NSRect(origin: .zero, size: size))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func draw(_ dirtyRect: NSRect) {
        image.draw(
            in: bounds,
            from: NSRect(origin: .zero, size: image.size),
            operation: .copy,
            fraction: 1,
            respectFlipped: false,
            hints: [.interpolation: NSImageInterpolation.high]
        )
    }

    static func imageAspect(_ image: NSImage) -> NSSize {
        if let rep = image.representations.first, rep.pixelsWide > 0, rep.pixelsHigh > 0 {
            return NSSize(width: CGFloat(rep.pixelsWide), height: CGFloat(rep.pixelsHigh))
        }
        return image.size
    }

    /// 铺满整张纸所需的缩放(面板百分比 = 此值 × 100)
    static func fitScale(imageSize: NSSize, paperSize: NSSize) -> CGFloat {
        guard imageSize.width > 0, imageSize.height > 0, paperSize.width > 0, paperSize.height > 0 else {
            return 1
        }
        return min(paperSize.width / imageSize.width, paperSize.height / imageSize.height)
    }
}
