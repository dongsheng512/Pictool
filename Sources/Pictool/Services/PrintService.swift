import AppKit

enum PrintScaleMode: String, CaseIterable, Identifiable {
    case fitPage = "适配页面"
    case actualSize = "实际大小"
    var id: String { rawValue }
}

@MainActor
enum PrintService {

    /// 使用标准打印面板打印图片;横向/纵向按图片宽高比自动选择。
    /// 非阻塞呈现(runOperationModal),避免与 SwiftUI sheet 关闭动画产生模态冲突。
    static func print(image: NSImage, mode: PrintScaleMode) {
        let info = NSPrintInfo.shared
        info.orientation = image.size.width >= image.size.height ? .landscape : .portrait
        let page = info.imageablePageBounds
        let view = PrintPageView(image: image, pageBounds: page, mode: mode)
        let operation = NSPrintOperation(view: view, printInfo: info)
        operation.canSpawnSeparateThread = true
        if let window = NSApp.keyWindow ?? NSApp.mainWindow {
            operation.runModal(for: window, delegate: nil, didRun: nil, contextInfo: nil)
        }
    }
}

/// 单页绘制视图:图像居中,按模式缩放
final class PrintPageView: NSView {

    private let image: NSImage
    private let pageBounds: CGRect
    private let mode: PrintScaleMode

    init(image: NSImage, pageBounds: CGRect, mode: PrintScaleMode) {
        self.image = image
        self.pageBounds = pageBounds
        self.mode = mode
        super.init(frame: pageBounds)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func draw(_ dirtyRect: NSRect) {
        let page = pageBounds
        let size = image.size
        let rect: CGRect
        switch mode {
        case .fitPage:
            let scale = min(page.width / size.width, page.height / size.height)
            let w = size.width * scale
            let h = size.height * scale
            rect = CGRect(x: page.midX - w / 2, y: page.midY - h / 2, width: w, height: h)
        case .actualSize:
            rect = CGRect(x: page.midX - size.width / 2, y: page.midY - size.height / 2,
                          width: size.width, height: size.height)
        }
        image.draw(in: rect)
    }
}
