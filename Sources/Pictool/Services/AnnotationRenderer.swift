import AppKit
import CoreImage
import CoreText

// MARKUP_PLAN.md 生存级约束:预览(降采样)与导出(全尺寸)必须走同一套绘制函数。
// 本渲染器内部先把坐标系翻成"显示坐标(y 向下)",文字与图片绘制再在局部翻转回来,
// 因此调用方只管提供画幅大小,不用关心 CG 上下文方向。

enum AnnotationRenderer {

    /// 把标记画进任意 CG 上下文。`ctx` 为常规方向(y 向上);`base` 仅在含马赛克时需要,
    /// 用于生成像素化/模糊效果底图。
    static func draw(_ annotations: [Annotation], in ctx: CGContext,
                     canvasSize: CGSize, base: CGImage?) {
        guard !annotations.isEmpty, canvasSize.width > 0, canvasSize.height > 0 else { return }
        ctx.saveGState()
        // 进入显示坐标(y 向下),后续所有归一化坐标直接乘画幅
        ctx.translateBy(x: 0, y: canvasSize.height)
        ctx.scaleBy(x: 1, y: -1)
        var pixelateCache: [CGFloat: CGImage] = [:]
        var blurCache: [CGFloat: CGImage] = [:]
        for annotation in annotations {
            switch annotation.kind {
            case let .text(anchor, content, sizeFraction, colorIndex):
                drawText(content, sizeFraction: MarkPalette.clampTextFraction(sizeFraction),
                         colorIndex: colorIndex, topLeft: anchor, in: ctx, canvasSize: canvasSize)
            case let .stroke(points, widthLevel, colorIndex, style):
                let width = MarkPalette.fraction(MarkPalette.widthTable(for: style), level: widthLevel) * canvasSize.width
                guard let path = strokePath(points, canvasSize: canvasSize) else { continue }
                ctx.saveGState()
                ctx.addPath(path)
                ctx.setStrokeColor(MarkPalette.color(colorIndex).cgColor)
                ctx.setLineWidth(width)
                ctx.setLineCap(.round)
                ctx.setLineJoin(.round)
                // 荧光笔半透明,同色叠笔自然加深(与预览.app 行为一致)
                ctx.setAlpha(style == .highlighter ? 0.45 : 1)
                ctx.strokePath()
                ctx.restoreGState()
            case let .mosaic(points, widthLevel, effect):
                let widthFraction = MarkPalette.fraction(MarkPalette.mosaicWidths, level: widthLevel)
                guard let path = strokePath(points, canvasSize: canvasSize) else { continue }
                let effectImage: CGImage?
                switch effect {
                case .pixelate:
                    let block = MarkPalette.fraction(MarkPalette.pixelateBlocks, level: widthLevel)
                    effectImage = pixelateCache[block] ?? base.flatMap { pixelated($0, blockFraction: block) }
                    pixelateCache[block] = effectImage
                case .blur:
                    let radius = MarkPalette.fraction(MarkPalette.blurRadii, level: widthLevel)
                    effectImage = blurCache[radius] ?? base.flatMap { gaussianBlurred($0, radiusFraction: radius) }
                    blurCache[radius] = effectImage
                }
                guard let effectImage else { continue }
                ctx.saveGState()
                ctx.addPath(path)
                ctx.setLineWidth(widthFraction * canvasSize.width)
                ctx.setLineCap(.round)
                ctx.setLineJoin(.round)
                // 把折线换成"描边区域",只在这一笔的范围内显示效果底图
                ctx.replacePathWithStrokedPath()
                ctx.clip()
                // 效果底图是常规方向图片,局部翻转回来再铺
                ctx.saveGState()
                ctx.translateBy(x: 0, y: canvasSize.height)
                ctx.scaleBy(x: 1, y: -1)
                ctx.draw(effectImage, in: CGRect(origin: .zero, size: canvasSize))
                ctx.restoreGState()
                ctx.restoreGState()
            case let .shape(kind, from, to, widthLevel, colorIndex):
                drawShape(kind, from: from, to: to,
                          widthFraction: MarkPalette.fraction(MarkPalette.strokeWidths, level: widthLevel),
                          colorIndex: colorIndex, in: ctx, canvasSize: canvasSize)
            }
        }
        ctx.restoreGState()
    }

    /// 形状:只描边;箭头为线段 + 实心三角头。显示坐标(y 向下)上下文。
    private static func drawShape(_ kind: ShapeKind, from: CGPoint, to: CGPoint,
                                  widthFraction: CGFloat, colorIndex: Int,
                                  in ctx: CGContext, canvasSize: CGSize) {
        let width = max(1, widthFraction * canvasSize.width)
        let color = MarkPalette.color(colorIndex).cgColor
        ctx.saveGState()
        ctx.setStrokeColor(color)
        ctx.setFillColor(color)
        ctx.setLineWidth(width)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        func point(_ p: CGPoint) -> CGPoint {
            CGPoint(x: p.x * canvasSize.width, y: p.y * canvasSize.height)
        }
        switch kind {
        case .rect, .ellipse:
            let norm = MarkupGeometry.standardizedRect(from: from, to: to)
            let pixelRect = CGRect(x: norm.minX * canvasSize.width,
                                   y: norm.minY * canvasSize.height,
                                   width: norm.width * canvasSize.width,
                                   height: norm.height * canvasSize.height)
            if kind == .rect {
                ctx.stroke(pixelRect)
            } else {
                let ellipse = CGPath(ellipseIn: pixelRect, transform: nil)
                ctx.addPath(ellipse)
                ctx.strokePath()
            }
        case .line, .arrow:
            let a = point(from), b = point(to)
            ctx.move(to: a)
            ctx.addLine(to: b)
            ctx.strokePath()
            if kind == .arrow,
               let head = MarkupGeometry.arrowHead(from: from, to: to,
                                                   widthFraction: widthFraction,
                                                   canvasSize: canvasSize) {
                let path = CGMutablePath()
                path.move(to: point(head.tip))
                path.addLine(to: point(head.baseA))
                path.addLine(to: point(head.baseB))
                path.closeSubpath()
                ctx.addPath(path)
                ctx.fillPath()
            }
        }
        ctx.restoreGState()
    }

    /// 透明底标记层(预览叠层用)
    static func renderOverlay(annotations: [Annotation], canvasSize: CGSize,
                              base: CGImage?) -> CGImage? {
        guard let ctx = CGContext(
            data: nil, width: max(1, Int(canvasSize.width)), height: max(1, Int(canvasSize.height)),
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        draw(annotations, in: ctx, canvasSize: canvasSize, base: base)
        return ctx.makeImage()
    }

    // MARK: 文字(CoreText;预览与导出同一度量与绘制路径)

    static func textSize(content: String, sizeFraction: CGFloat, canvasWidth: CGFloat) -> CGSize {
        let fontSize = sizeFraction * canvasWidth
        guard fontSize > 0 else { return .zero }
        let font = makeFont(size: fontSize)
        let lineHeight = fontSize * 1.35
        var maxWidth: CGFloat = 0
        var lineCount = 0
        for line in content.split(separator: "\n", omittingEmptySubsequences: false) {
            lineCount += 1
            guard let astr = CFAttributedStringCreate(nil, line as CFString, [
                kCTFontAttributeName: font,
            ] as CFDictionary) else { continue }
            let ctLine = CTLineCreateWithAttributedString(astr)
            var ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0
            maxWidth = max(maxWidth, CGFloat(CTLineGetTypographicBounds(ctLine, &ascent, &descent, &leading)))
        }
        return CGSize(width: maxWidth, height: CGFloat(max(lineCount, 1)) * lineHeight)
    }

    /// 在显示坐标(y 向下)上下文里画文字块。
    /// `topLeft` 是**归一化**左上角(0...1),不要传入像素坐标。
    /// 上下文必须是已被外层翻转过的;文字在局部再翻回,保证字形直立的同一份代码两端通用。
    static func drawText(_ content: String, sizeFraction: CGFloat, colorIndex: Int,
                         topLeft: CGPoint, in ctx: CGContext, canvasSize: CGSize) {
        let fontSize = sizeFraction * canvasSize.width
        guard fontSize > 0 else { return }
        let font = makeFont(size: fontSize)
        let color = MarkPalette.color(colorIndex).usingColorSpace(.deviceRGB) ?? .black
        let lineHeight = fontSize * 1.35
        let ascent = CTFontGetAscent(font)
        let x = topLeft.x * canvasSize.width
        let yTop = topLeft.y * canvasSize.height
        for (i, line) in content.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let baselineY = yTop + CGFloat(i) * lineHeight + ascent
            ctx.saveGState()
            ctx.translateBy(x: x, y: baselineY)
            ctx.scaleBy(x: 1, y: -1)
            if let astr = CFAttributedStringCreate(nil, line as CFString, [
                kCTFontAttributeName: font,
                kCTForegroundColorAttributeName: color.cgColor,
            ] as CFDictionary) {
                let ctLine = CTLineCreateWithAttributedString(astr)
                ctx.textPosition = .zero
                CTLineDraw(ctLine, ctx)
            }
            ctx.restoreGState()
        }
    }

    // MARK: 效果底图(M4 马赛克/模糊)

    /// 效果缓存条目:强持有 base。若只存结果图,base 释放后同尺寸新图的
    /// ObjectIdentifier 可能复用同址,导致马赛克/模糊烙上另一张图的像素。
    private final class EffectCacheEntry {
        let base: CGImage
        let image: CGImage
        init(base: CGImage, image: CGImage) {
            self.base = base
            self.image = image
        }
    }

    private static let effectCache: NSCache<NSString, EffectCacheEntry> = {
        let cache = NSCache<NSString, EffectCacheEntry>()
        cache.countLimit = 8
        return cache
    }()

    static func pixelated(_ base: CGImage, blockFraction: CGFloat) -> CGImage? {
        let cacheKey = "p-\(ObjectIdentifier(base))-\(blockFraction)" as NSString
        if let entry = effectCache.object(forKey: cacheKey), entry.base === base { return entry.image }
        let blockPx = max(1, blockFraction * CGFloat(base.width))
        let smallW = max(1, Int((CGFloat(base.width) / blockPx).rounded()))
        let smallH = max(1, Int((CGFloat(base.height) / blockPx).rounded()))
        // 降到块级分辨率再最近邻放大,得到硬边像素化;两端都必须 .none,否则块边界发糊
        guard let smallCtx = CGContext(
            data: nil, width: smallW, height: smallH, bitsPerComponent: 8, bytesPerRow: 0,
            space: base.colorSpace ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        smallCtx.interpolationQuality = .none
        smallCtx.draw(base, in: CGRect(x: 0, y: 0, width: smallW, height: smallH))
        guard let small = smallCtx.makeImage(),
              let bigCtx = CGContext(
                  data: nil, width: base.width, height: base.height, bitsPerComponent: 8, bytesPerRow: 0,
                  space: base.colorSpace ?? CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else { return nil }
        bigCtx.interpolationQuality = .none
        bigCtx.draw(small, in: CGRect(x: 0, y: 0, width: base.width, height: base.height))
        guard let result = bigCtx.makeImage() else { return nil }
        effectCache.setObject(EffectCacheEntry(base: base, image: result), forKey: cacheKey)
        return result
    }

    private static let ciContext = CIContext(options: nil)

    static func gaussianBlurred(_ base: CGImage, radiusFraction: CGFloat) -> CGImage? {
        let cacheKey = "b-\(ObjectIdentifier(base))-\(radiusFraction)" as NSString
        if let entry = effectCache.object(forKey: cacheKey), entry.base === base { return entry.image }
        let input = CIImage(cgImage: base)
        // 先边缘延展再模糊,避免高斯在四边吃出透明带;最后裁回原幅
        let clamped = input.clampedToExtent()
        guard let filter = CIFilter(name: "CIGaussianBlur") else { return nil }
        filter.setValue(clamped, forKey: kCIInputImageKey)
        filter.setValue(radiusFraction * CGFloat(base.width), forKey: kCIInputRadiusKey)
        guard let output = filter.outputImage?.cropped(to: input.extent) else { return nil }
        guard let result = ciContext.createCGImage(output, from: input.extent) else { return nil }
        effectCache.setObject(EffectCacheEntry(base: base, image: result), forKey: cacheKey)
        return result
    }

    // MARK: 私有

    private static func makeFont(size: CGFloat) -> CTFont {
        let nsFont = NSFont.systemFont(ofSize: size, weight: .medium)
        return CTFontCreateWithFontDescriptor(nsFont.fontDescriptor, size, nil)
    }

    private static func strokePath(_ points: [CGPoint], canvasSize: CGSize) -> CGPath? {
        guard !points.isEmpty else { return nil }
        let scaled = points.map { CGPoint(x: $0.x * canvasSize.width, y: $0.y * canvasSize.height) }
        let path = CGMutablePath()
        if scaled.count == 1 {
            // 单点轻点:用一小段重合线段表现圆点
            path.move(to: scaled[0])
            path.addLine(to: CGPoint(x: scaled[0].x + 0.01, y: scaled[0].y))
        } else {
            path.move(to: scaled[0])
            for p in scaled.dropFirst() { path.addLine(to: p) }
        }
        return path
    }
}
