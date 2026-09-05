import AppKit
import CoreText

// MARKUP_PLAN.md M2 — 导出水印。落点是导出面板选项与偏好设置,不是画布交互:
// 水印是"每张都加"的批量策略,九宫格定位/平铺布局全是纯函数(单测覆盖)。

enum WatermarkPosition: String, Codable, CaseIterable, Identifiable {
    case topLeft, topCenter, topRight
    case centerLeft, center, centerRight
    case bottomLeft, bottomCenter, bottomRight

    var id: String { rawValue }

    var label: String {
        switch self {
        case .topLeft: "左上"; case .topCenter: "上中"; case .topRight: "右上"
        case .centerLeft: "左中"; case .center: "居中"; case .centerRight: "右中"
        case .bottomLeft: "左下"; case .bottomCenter: "下中"; case .bottomRight: "右下"
        }
    }
}

struct WatermarkSettings: Codable, Equatable, Sendable {
    var enabled = false
    /// 文字水印内容;为空且无 logo 时水印不生效
    var text = ""
    var useLogo = false
    var logoPath: String?
    var position: WatermarkPosition = .bottomRight
    /// 0.1...1
    var opacity = 0.6
    /// 字号/logo 宽度,相对图宽
    var sizeFraction = 0.035
    var tiled = false
    /// 平铺间距,相对图宽
    var tileSpacing = 0.28

    static let storageKey = "watermarkSettings"

    static func load() -> WatermarkSettings {
        guard let data = UserDefaults.standard.data(forKey: storageKey) else { return WatermarkSettings() }
        return (try? JSONDecoder().decode(WatermarkSettings.self, from: data)) ?? WatermarkSettings()
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: Self.storageKey)
        }
    }

    var trimmedText: String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 是否有可绘制的水印内容。勾了 logo 但还没选文件时回退到文字。
    var hasContent: Bool {
        if useLogo, logoPath != nil { return true }
        return !trimmedText.isEmpty
    }

    /// 把用户选的 PNG 复制进 Application Support,偏好里只存这份稳定路径。
    static func installLogo(from source: URL) throws -> String {
        let dest = logoStorageURL
        try FileManager.default.createDirectory(
            at: dest.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        if FileManager.default.fileExists(atPath: dest.path) {
            try FileManager.default.removeItem(at: dest)
        }
        try FileManager.default.copyItem(at: source, to: dest)
        return dest.path
    }

    static func clearLogoFile() {
        try? FileManager.default.removeItem(at: logoStorageURL)
    }

    static var logoStorageURL: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent("PureView", isDirectory: true)
            .appendingPathComponent("watermark-logo.png")
    }
}

/// 九宫格定位与平铺布局(纯函数,单测覆盖)
enum WatermarkLayout {

    /// 内容块左上角;画幅内留 marginFraction 边距
    static func origin(position: WatermarkPosition, canvasSize: CGSize,
                       contentSize: CGSize, marginFraction: CGFloat = 0.02) -> CGPoint {
        let margin = marginFraction * canvasSize.width
        let x: CGFloat
        switch position {
        case .topLeft, .centerLeft, .bottomLeft: x = margin
        case .topCenter, .center, .bottomCenter: x = (canvasSize.width - contentSize.width) / 2
        case .topRight, .centerRight, .bottomRight: x = canvasSize.width - contentSize.width - margin
        }
        let y: CGFloat
        switch position {
        case .topLeft, .topCenter, .topRight: y = margin
        case .centerLeft, .center, .centerRight: y = (canvasSize.height - contentSize.height) / 2
        case .bottomLeft, .bottomCenter, .bottomRight: y = canvasSize.height - contentSize.height - margin
        }
        return CGPoint(x: x, y: y)
    }

    /// 平铺网格:以画幅中心为原点,间距 tileSpacing×宽,覆盖到对角线长度(倾斜后仍铺满四角)
    static func tiledOffsets(canvasSize: CGSize, spacingFraction: CGFloat) -> [CGPoint] {
        let step = max(1, spacingFraction * canvasSize.width)
        let diagonal = hypot(canvasSize.width, canvasSize.height)
        var offsets: [CGPoint] = []
        var x = -diagonal
        while x <= diagonal {
            var y = -diagonal
            while y <= diagonal {
                offsets.append(CGPoint(x: x, y: y))
                y += step
            }
            x += step
        }
        return offsets
    }
}

enum WatermarkRenderer {

    /// 调用方传入常规方向(y 向上)的输出上下文。内部翻成 y 向下再画,
    /// 与 `WatermarkLayout.origin`(显示坐标,上小下大)及 `AnnotationRenderer.drawText` 对齐。
    static func draw(_ settings: WatermarkSettings, in ctx: CGContext, canvasSize: CGSize) {
        guard settings.enabled, settings.hasContent else { return }
        let contentSize = contentSize(settings: settings, canvasSize: canvasSize)
        guard contentSize.width > 0, contentSize.height > 0 else { return }

        ctx.saveGState()
        ctx.translateBy(x: 0, y: canvasSize.height)
        ctx.scaleBy(x: 1, y: -1)
        ctx.setAlpha(CGFloat(min(max(settings.opacity, 0.05), 1)))

        let fraction = resolvedSizeFraction(settings: settings, canvasSize: canvasSize)
        // 文字靠投影压在亮底上也能看清,不用描边(描边会和填充错位成两份字)。
        if !(settings.useLogo && loadLogo(settings) != nil) {
            let shadowRadius = max(2, fraction * canvasSize.width * 0.12)
            ctx.setShadow(offset: CGSize(width: 0, height: 0), blur: shadowRadius,
                          color: NSColor.black.withAlphaComponent(0.55).cgColor)
        }

        if settings.tiled {
            // 倾斜 -30°(显示方向),网格在旋转后的空间铺开
            ctx.translateBy(x: canvasSize.width / 2, y: canvasSize.height / 2)
            ctx.rotate(by: -.pi / 6)
            ctx.translateBy(x: -canvasSize.width / 2, y: -canvasSize.height / 2)
            for offset in WatermarkLayout.tiledOffsets(canvasSize: canvasSize, spacingFraction: settings.tileSpacing) {
                let origin = CGPoint(
                    x: canvasSize.width / 2 + offset.x - contentSize.width / 2,
                    y: canvasSize.height / 2 + offset.y - contentSize.height / 2
                )
                drawContent(settings: settings, origin: origin, contentSize: contentSize,
                            in: ctx, canvasSize: canvasSize)
            }
        } else {
            let origin = WatermarkLayout.origin(position: settings.position,
                                                canvasSize: canvasSize, contentSize: contentSize)
            drawContent(settings: settings, origin: origin, contentSize: contentSize,
                        in: ctx, canvasSize: canvasSize)
        }
        ctx.restoreGState()
    }

    /// 透明底水印层,与导出同一套 `draw`。预览叠在原图上,避免 SwiftUI Text 把长文截成 "C..."。
    static func overlay(_ settings: WatermarkSettings, canvasSize: CGSize, force: Bool = false) -> CGImage? {
        var s = settings
        if force, s.hasContent { s.enabled = true }
        guard s.enabled, s.hasContent else { return nil }
        let w = max(1, Int(canvasSize.width.rounded()))
        let h = max(1, Int(canvasSize.height.rounded()))
        guard let ctx = CGContext(
            data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        draw(s, in: ctx, canvasSize: CGSize(width: w, height: h))
        return ctx.makeImage()
    }

    /// 把水印烙到图上,返回新图。未启用或没有内容时原样返回。
    static func stamp(_ settings: WatermarkSettings, onto image: CGImage) -> CGImage {
        guard settings.enabled, settings.hasContent else { return image }
        let w = image.width, h = image.height
        guard let ctx = CGContext(
            data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
            space: image.colorSpace ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return image }
        let size = CGSize(width: w, height: h)
        ctx.draw(image, in: CGRect(origin: .zero, size: size))
        draw(settings, in: ctx, canvasSize: size)
        return ctx.makeImage() ?? image
    }

    /// 预览用:把底图缩到 `maxPixel` 长边再烙水印,相对位置/大小与导出一致。
    /// `force` 为 true 时只要有内容就画(设置面板预览不必先勾选启用)。
    static func preview(_ settings: WatermarkSettings, onto base: CGImage,
                        maxPixel: Int = 480, force: Bool = false) -> CGImage? {
        let longest = max(base.width, base.height)
        let scale = longest > maxPixel ? CGFloat(maxPixel) / CGFloat(longest) : 1
        let w = max(1, Int((CGFloat(base.width) * scale).rounded()))
        let h = max(1, Int((CGFloat(base.height) * scale).rounded()))
        guard let ctx = CGContext(
            data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        let size = CGSize(width: w, height: h)
        ctx.interpolationQuality = .high
        ctx.draw(base, in: CGRect(origin: .zero, size: size))
        guard let scaled = ctx.makeImage() else { return nil }
        var preview = settings
        if force, preview.hasContent { preview.enabled = true }
        return stamp(preview, onto: scaled)
    }

    /// 内容块尺寸:文字按 CoreText 度量;过宽时缩小到画幅内。logo 按宽等比。
    static func contentSize(settings: WatermarkSettings, canvasSize: CGSize) -> CGSize {
        let fraction = resolvedSizeFraction(settings: settings, canvasSize: canvasSize)
        let width = fraction * canvasSize.width
        if settings.useLogo, let logo = loadLogo(settings) {
            let aspect = CGFloat(logo.height) / max(1, CGFloat(logo.width))
            return CGSize(width: width, height: width * aspect)
        }
        return AnnotationRenderer.textSize(
            content: settings.trimmedText, sizeFraction: fraction, canvasWidth: canvasSize.width
        )
    }

    /// 长文按设定字号会画出画幅时,等比缩小到左右各留 2% 边。
    static func resolvedSizeFraction(settings: WatermarkSettings, canvasSize: CGSize) -> CGFloat {
        var fraction = min(max(settings.sizeFraction, 0.01), 0.4)
        if settings.useLogo, loadLogo(settings) != nil { return fraction }
        let text = settings.trimmedText
        guard !text.isEmpty, canvasSize.width > 0 else { return fraction }
        let maxWidth = canvasSize.width * 0.96
        // 字体度量不是严格线性,缩一次可能仍超宽,最多收敛三轮。
        for _ in 0..<3 {
            let raw = AnnotationRenderer.textSize(
                content: text, sizeFraction: fraction, canvasWidth: canvasSize.width
            )
            guard raw.width > maxWidth, raw.width > 0 else { break }
            fraction *= maxWidth / raw.width
            fraction = max(fraction, 0.005)
        }
        return fraction
    }

    // MARK: 私有

    /// `origin` 为显示坐标(y 向下)的像素左上角。
    private static func drawContent(settings: WatermarkSettings, origin: CGPoint,
                                    contentSize: CGSize, in ctx: CGContext, canvasSize: CGSize) {
        if settings.useLogo, let logo = loadLogo(settings) {
            ctx.saveGState()
            ctx.translateBy(x: origin.x, y: origin.y + contentSize.height)
            ctx.scaleBy(x: 1, y: -1)
            ctx.draw(logo, in: CGRect(origin: .zero, size: contentSize))
            ctx.restoreGState()
            return
        }
        let text = settings.trimmedText
        guard !text.isEmpty, canvasSize.width > 0, canvasSize.height > 0 else { return }
        let fraction = resolvedSizeFraction(settings: settings, canvasSize: canvasSize)
        let normalized = CGPoint(x: origin.x / canvasSize.width, y: origin.y / canvasSize.height)
        drawWatermarkText(text, sizeFraction: fraction, topLeft: normalized,
                          in: ctx, canvasSize: canvasSize)
    }

    /// 水印文字独立绘制:纯白填充,不走标记描边。上下文须已是 y 向下。
    private static func drawWatermarkText(_ content: String, sizeFraction: CGFloat,
                                          topLeft: CGPoint, in ctx: CGContext, canvasSize: CGSize) {
        let fontSize = sizeFraction * canvasSize.width
        guard fontSize > 0 else { return }
        let nsFont = NSFont.systemFont(ofSize: fontSize, weight: .medium)
        let font = CTFontCreateWithFontDescriptor(nsFont.fontDescriptor, fontSize, nil)
        let lineHeight = fontSize * 1.35
        let ascent = CTFontGetAscent(font)
        let x = topLeft.x * canvasSize.width
        let yTop = topLeft.y * canvasSize.height
        let white = CGColor(gray: 1, alpha: 1)
        for (i, line) in content.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let baselineY = yTop + CGFloat(i) * lineHeight + ascent
            ctx.saveGState()
            ctx.translateBy(x: x, y: baselineY)
            ctx.scaleBy(x: 1, y: -1)
            if let astr = CFAttributedStringCreate(nil, line as CFString, [
                kCTFontAttributeName: font,
                kCTForegroundColorAttributeName: white,
            ] as CFDictionary) {
                let ctLine = CTLineCreateWithAttributedString(astr)
                ctx.textPosition = .zero
                CTLineDraw(ctLine, ctx)
            }
            ctx.restoreGState()
        }
    }

    private static func loadLogo(_ settings: WatermarkSettings) -> CGImage? {
        guard let path = settings.logoPath else { return nil }
        let image = NSImage(contentsOfFile: path)
        return image?.cgImage(forProposedRect: nil, context: nil, hints: nil)
    }
}
