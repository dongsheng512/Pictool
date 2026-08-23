import AppKit

@MainActor
enum PrintService {

    /// 使用标准打印面板打印图片。方向与缩放百分比由原生打印面板设置。
    /// 图像默认适配可打印区域并居中;Scaling 控件在此基础上做相对百分比调整。
    static func print(image: NSImage) {
        let info = NSPrintInfo.shared
        info.horizontalPagination = .automatic
        info.verticalPagination = .automatic
        info.scalingFactor = 1.0

        let imageable = info.imageablePageBounds
        let page = CGRect(origin: .zero, size: info.paperSize)
        let view = PrintPageView(image: image, pageBounds: page, imageableBounds: imageable)
        let operation = NSPrintOperation(view: view, printInfo: info)
        operation.canSpawnSeparateThread = true
        operation.printPanel.options.insert([.showsOrientation, .showsScaling])
        if let window = NSApp.keyWindow ?? NSApp.mainWindow {
            operation.runModal(for: window, delegate: nil, didRun: nil, contextInfo: nil)
        }
    }
}

/// 整页绘制视图:图像按可打印区域适配缩放后居中,预览和输出一致。
final class PrintPageView: NSView {

    private let image: NSImage
    private let imageableBounds: CGRect

    init(image: NSImage, pageBounds: CGRect, imageableBounds: CGRect) {
        self.image = image
        self.imageableBounds = imageableBounds
        super.init(frame: pageBounds)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func draw(_ dirtyRect: NSRect) {
        // 用位图像素做适配基准:image.size 受 DPI 标注影响(3000px@150dpi=2000pt),
        // 会让适配结果偏离像素语义;像素尺寸与打印面板预览的期望一致。
        let rep = image.representations.first
        let pixelWidth = CGFloat(rep?.pixelsWide ?? 0)
        let pixelHeight = CGFloat(rep?.pixelsHigh ?? 0)
        let imageSize = (pixelWidth > 0 && pixelHeight > 0)
            ? CGSize(width: pixelWidth, height: pixelHeight)
            : image.size
        let page = imageableBounds

        // 按可打印区域适配,保持宽高比
        let scale = min(page.width / imageSize.width, page.height / imageSize.height)
        let drawWidth = imageSize.width * scale
        let drawHeight = imageSize.height * scale
        let rect = CGRect(
            x: page.midX - drawWidth / 2,
            y: page.midY - drawHeight / 2,
            width: drawWidth,
            height: drawHeight
        )

        image.draw(in: rect, from: .zero, operation: .copy, fraction: 1,
                   respectFlipped: false, hints: [.interpolation: NSImageInterpolation.high])
    }
}
