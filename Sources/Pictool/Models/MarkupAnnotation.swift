import AppKit
import CoreText

// MARKUP_PLAN.md — 画布标记图元与几何纯函数。
// 坐标统一为归一化(0...1,原点图片左上),与裁切选区同语义;
// 字号/线宽/马赛克块大小均为相对图宽的千分比,预览与导出按各自画幅换算。

/// 画布标记。按 MARKUP_PLAN 从第一天就是枚举:text(A1)/ stroke(A3)/ mosaic(A4)。
struct Annotation: Identifiable, Equatable, Sendable {
    let id: UUID
    var kind: Kind

    init(id: UUID = UUID(), kind: Kind) {
        self.id = id
        self.kind = kind
    }

    enum Kind: Equatable, Sendable {
        /// 锚点为文字块左上角(归一化);sizeFraction = 字号/画布宽(连续,三档 chip 是预设)
        case text(anchor: CGPoint, content: String, sizeFraction: CGFloat, colorIndex: Int)
        /// 笔迹;style 决定实线或荧光(半透明、更宽)
        case stroke(points: [CGPoint], widthLevel: Int, colorIndex: Int, style: StrokeStyleKind)
        /// 笔迹 = 效果蒙版;effect 决定蒙版下显示像素化还是模糊底图
        case mosaic(points: [CGPoint], widthLevel: Int, effect: MosaicEffect)
        /// 形状(B2):只描边;rect/ellipse 用 from/to 对角点,line/arrow 用两端点(arrow 指向 to)
        case shape(kind: ShapeKind, from: CGPoint, to: CGPoint, widthLevel: Int, colorIndex: Int)
    }
}

/// 笔迹样式:实线 / 荧光笔(半透明、更宽)
enum StrokeStyleKind: String, CaseIterable, Identifiable, Sendable {
    case solid
    case highlighter
    var id: String { rawValue }
    var label: String { self == .solid ? "实线" : "荧光" }
}

enum EditTool: String, CaseIterable, Identifiable, Sendable {
    case crop, text, brush, mosaic, eraser, shape
    var id: String { rawValue }
    var label: String {
        switch self {
        case .crop: "裁切"
        case .text: "文字"
        case .brush: "画笔"
        case .mosaic: "马赛克"
        case .eraser: "橡皮"
        case .shape: "形状"
        }
    }
    var systemImage: String {
        switch self {
        case .crop: "crop"
        case .text: "character.cursor.ibeam"
        case .brush: "paintbrush.pointed"
        case .mosaic: "squareshape.split.3x3"
        case .eraser: "eraser"
        case .shape: "rectangle.dashed"
        }
    }
}

/// 形状标注种类(B2)。from/to 为对角点或端点,归一化坐标。
enum ShapeKind: String, CaseIterable, Identifiable, Sendable {
    case rect, ellipse, line, arrow
    var id: String { rawValue }
    var label: String {
        switch self {
        case .rect: "矩形"
        case .ellipse: "椭圆"
        case .line: "直线"
        case .arrow: "箭头"
        }
    }
}

enum MosaicEffect: String, CaseIterable, Identifiable, Sendable {
    case pixelate
    case blur
    var id: String { rawValue }
    var label: String { self == .pixelate ? "打码" : "模糊" }
}

/// 标记工具共享的调色盘与档位(千分比表)。档位取值越界时夹到合法区间。
enum MarkPalette {

    static let colors: [NSColor] = [
        .black,
        .white,
        NSColor(red: 0.90, green: 0.18, blue: 0.16, alpha: 1),
        NSColor(red: 0.98, green: 0.76, blue: 0.04, alpha: 1),
        NSColor(red: 0.13, green: 0.64, blue: 0.29, alpha: 1),
        NSColor(red: 0.13, green: 0.42, blue: 0.92, alpha: 1),
    ]

    static func color(_ index: Int) -> NSColor {
        colors.indices.contains(index) ? colors[index] : .black
    }

    static let textSizes: [CGFloat] = [0.030, 0.048, 0.070]
    static let textFractionRange: ClosedRange<CGFloat> = 0.015...0.120
    static let strokeWidths: [CGFloat] = [0.004, 0.008, 0.016]
    /// 荧光笔:更宽,渲染时叠加 45% alpha
    static let highlighterWidths: [CGFloat] = [0.012, 0.020, 0.032]
    static let mosaicWidths: [CGFloat] = [0.035, 0.060, 0.100]
    static let pixelateBlocks: [CGFloat] = [0.012, 0.022, 0.038]
    static let blurRadii: [CGFloat] = [0.006, 0.012, 0.022]

    /// 实线/荧光共用:按样式取线宽表
    static func widthTable(for style: StrokeStyleKind) -> [CGFloat] {
        style == .highlighter ? highlighterWidths : strokeWidths
    }

    static func clampTextFraction(_ fraction: CGFloat) -> CGFloat {
        min(max(fraction, textFractionRange.lowerBound), textFractionRange.upperBound)
    }

    /// 连续字号反映到三档 chip 的高亮(取最近档)
    static func nearestTextLevel(_ fraction: CGFloat) -> Int {
        var best = 0
        var bestDist = CGFloat.greatestFiniteMagnitude
        for (i, size) in textSizes.enumerated() {
            let dist = abs(size - fraction)
            if dist < bestDist { bestDist = dist; best = i }
        }
        return best
    }

    static func fraction(_ table: [CGFloat], level: Int) -> CGFloat {
        let idx = min(max(0, level), table.count - 1)
        return table[idx]
    }

    /// 白(1)、黄(3)为浅色,描边用近黑;其余近白。
    static func isLightColor(_ index: Int) -> Bool {
        index == 1 || index == 3
    }
}

/// 标记几何纯函数(单测覆盖)。所有坐标为归一化值。
enum MarkupGeometry {

    /// 点到线段的最短距离
    static func distance(_ p: CGPoint, segment a: CGPoint, _ b: CGPoint) -> CGFloat {
        let abx = b.x - a.x, aby = b.y - a.y
        let apx = p.x - a.x, apy = p.y - a.y
        let lengthSq = abx * abx + aby * aby
        if lengthSq == 0 { return hypot(apx, apy) }
        let t = min(max(0, (apx * abx + apy * aby) / lengthSq), 1)
        let cx = a.x + t * abx, cy = a.y + t * aby
        return hypot(p.x - cx, p.y - cy)
    }

    /// 笔迹(折线)是否覆盖某点:**像素空间**算距离(归一化空间非等比,横竖容差会不一致)。
    /// 容差 = 线宽一半,另留固定小量便于点选细线。
    static func stroke(_ points: [CGPoint], contains point: CGPoint,
                       widthFraction: CGFloat, canvasSize: CGSize) -> Bool {
        guard let w = canvasSize.width > 0 ? canvasSize.width : nil, canvasSize.height > 0 else { return false }
        func px(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x * w, y: p.y * canvasSize.height) }
        let target = px(point)
        let tolerance = max(widthFraction / 2, 0.004) * w + 0.006 * w
        if points.count == 1, let only = points.first {
            return distance(target, segment: px(only), px(only)) <= tolerance
        }
        for i in 1..<points.count {
            if distance(target, segment: px(points[i - 1]), px(points[i])) <= tolerance { return true }
        }
        return false
    }

    /// 拖动后锚点夹取到 0...1
    static func moved(anchor: CGPoint, by delta: CGSize) -> CGPoint {
        CGPoint(x: min(max(0, anchor.x + delta.width), 1),
                y: min(max(0, anchor.y + delta.height), 1))
    }

    static func translated(points: [CGPoint], dx: CGFloat, dy: CGFloat) -> [CGPoint] {
        points.map { CGPoint(x: $0.x + dx, y: $0.y + dy) }
    }

    /// 整笔平移并夹回画布:任一点越界时收紧位移量,笔不拆散、不出界。
    static func clampedTranslate(points: [CGPoint], dx: CGFloat, dy: CGFloat) -> [CGPoint] {
        guard !points.isEmpty else { return points }
        var minX = points[0].x, maxX = points[0].x, minY = points[0].y, maxY = points[0].y
        for p in points {
            minX = min(minX, p.x); maxX = max(maxX, p.x)
            minY = min(minY, p.y); maxY = max(maxY, p.y)
        }
        let shiftX = min(max(dx, -minX), 1 - maxX)
        let shiftY = min(max(dy, -minY), 1 - maxY)
        return points.map { CGPoint(x: $0.x + shiftX, y: $0.y + shiftY) }
    }

    // MARK: 形状(B2)

    /// from/to 对角点转正矩形(负宽高翻转)
    static func standardizedRect(from: CGPoint, to: CGPoint) -> CGRect {
        CGRect(x: min(from.x, to.x), y: min(from.y, to.y),
               width: abs(to.x - from.x), height: abs(to.y - from.y))
    }

    /// 箭头头部几何:tip 在 to 端。**在像素空间计算**(归一化空间非等比,横竖箭头会失真),
    /// 头长(像素)= max(3×线宽像素, 画幅短边 2%);返回值已换回归一化坐标。
    static func arrowHead(from: CGPoint, to: CGPoint, widthFraction: CGFloat,
                          canvasSize: CGSize) -> (tip: CGPoint, baseA: CGPoint, baseB: CGPoint)? {
        let w = canvasSize.width, h = canvasSize.height
        guard w > 0, h > 0 else { return nil }
        let a = CGPoint(x: from.x * w, y: from.y * h)
        let b = CGPoint(x: to.x * w, y: to.y * h)
        let dx = b.x - a.x, dy = b.y - a.y
        let length = hypot(dx, dy)
        guard length > 0 else { return nil }
        let headPx = max(3 * widthFraction * w, 0.02 * min(w, h))
        let ux = dx / length, uy = dy / length
        let backX = b.x - ux * headPx
        let backY = b.y - uy * headPx
        let half = headPx / 2
        let px = -uy * half, py = ux * half
        return (to,
                CGPoint(x: (backX + px) / w, y: (backY + py) / h),
                CGPoint(x: (backX - px) / w, y: (backY - py) / h))
    }

    /// 形状包围盒(含线宽外扩;箭头含头部)
    static func shapeBounds(kind: ShapeKind, from: CGPoint, to: CGPoint,
                            widthFraction: CGFloat, canvasSize: CGSize) -> CGRect? {
        let pad = widthFraction / 2
        var minX = min(from.x, to.x), maxX = max(from.x, to.x)
        var minY = min(from.y, to.y), maxY = max(from.y, to.y)
        if kind == .arrow, let head = arrowHead(from: from, to: to, widthFraction: widthFraction,
                                                canvasSize: canvasSize) {
            for p in [head.tip, head.baseA, head.baseB] {
                minX = min(minX, p.x); maxX = max(maxX, p.x)
                minY = min(minY, p.y); maxY = max(maxY, p.y)
            }
        }
        guard maxX > minX, maxY > minY else { return nil }
        return CGRect(x: minX - pad, y: minY - pad,
                      width: maxX - minX + pad * 2, height: maxY - minY + pad * 2)
    }

    /// 形状命中:rect/ellipse 按 bounds 内含(便于移动);line/arrow 按线段距离,箭头另含头部三角
    static func hitShape(kind: ShapeKind, from: CGPoint, to: CGPoint, widthFraction: CGFloat,
                         canvasSize: CGSize, at point: CGPoint) -> Bool {
        switch kind {
        case .rect, .ellipse:
            return standardizedRect(from: from, to: to)
                .insetBy(dx: -0.006, dy: -0.006).contains(point)
        case .line, .arrow:
            guard canvasSize.width > 0, canvasSize.height > 0 else { return false }
            let tolerance = (max(widthFraction / 2, 0.004) + 0.006) * canvasSize.width
            let a = CGPoint(x: from.x * canvasSize.width, y: from.y * canvasSize.height)
            let b = CGPoint(x: to.x * canvasSize.width, y: to.y * canvasSize.height)
            let target = CGPoint(x: point.x * canvasSize.width, y: point.y * canvasSize.height)
            if distance(target, segment: a, b) <= tolerance { return true }
            guard kind == .arrow,
                  let head = arrowHead(from: from, to: to, widthFraction: widthFraction,
                                       canvasSize: canvasSize) else { return false }
            return triangleContains(point, a: head.tip, b: head.baseA, c: head.baseB)
        }
    }

    /// 点是否在三角形内(符号法,含退化边)
    private static func triangleContains(_ p: CGPoint, a: CGPoint, b: CGPoint, c: CGPoint) -> Bool {
        let signs = [cross(b, a, p), cross(c, b, p), cross(a, c, p)]
        let hasPositive = signs.contains { $0 > 0 }
        let hasNegative = signs.contains { $0 < 0 }
        return !(hasPositive && hasNegative)
    }

    private static func cross(_ a: CGPoint, _ b: CGPoint, _ p: CGPoint) -> CGFloat {
        (a.x - p.x) * (b.y - p.y) - (a.y - p.y) * (b.x - p.x)
    }

    /// Ramer–Douglas–Peucker 抽稀。首尾点恒保留;直线被压缩到两端,拐点保留。
    static func rdp(_ points: [CGPoint], epsilon: CGFloat) -> [CGPoint] {
        guard points.count > 2, epsilon > 0 else { return points }
        var keep = [Bool](repeating: false, count: points.count)
        keep[0] = true
        keep[points.count - 1] = true
        var stack = [(0, points.count - 1)]
        while let (start, end) = stack.popLast() {
            guard end > start + 1 else { continue }
            var maxDist: CGFloat = 0
            var maxIdx = start
            for i in (start + 1)..<end {
                let d = distance(points[i], segment: points[start], points[end])
                if d > maxDist { maxDist = d; maxIdx = i }
            }
            if maxDist > epsilon {
                keep[maxIdx] = true
                stack.append((start, maxIdx))
                stack.append((maxIdx, end))
            }
        }
        return points.enumerated().compactMap { keep[$0.offset] ? $0.element : nil }
    }

    /// 笔迹的归一化包围盒(含线宽外扩),无点返回 nil
    static func strokeBounds(_ points: [CGPoint], widthFraction: CGFloat) -> CGRect? {
        guard let first = points.first else { return nil }
        var minX = first.x, maxX = first.x, minY = first.y, maxY = first.y
        for p in points {
            minX = min(minX, p.x); maxX = max(maxX, p.x)
            minY = min(minY, p.y); maxY = max(maxY, p.y)
        }
        let pad = widthFraction / 2
        return CGRect(x: minX - pad, y: minY - pad,
                      width: maxX - minX + pad * 2, height: maxY - minY + pad * 2)
    }

    /// 文字命中盒,归一化坐标。`anchor` 为块左上角;度量与 `AnnotationRenderer.textSize` 同一路径。
    /// 最短边至少 0.02,避免小字点不中。
    static func textHitRect(anchor: CGPoint, content: String, sizeFraction: CGFloat,
                            imageSize: CGSize) -> CGRect {
        let fraction = MarkPalette.clampTextFraction(sizeFraction)
        let pixel = AnnotationRenderer.textSize(
            content: content, sizeFraction: fraction, canvasWidth: max(1, imageSize.width)
        )
        let width = imageSize.width > 0 ? pixel.width / imageSize.width : 0
        let height = imageSize.height > 0 ? pixel.height / imageSize.height : 0
        let minHit: CGFloat = 0.02
        return CGRect(
            x: min(max(0, anchor.x), 1),
            y: min(max(0, anchor.y), 1),
            width: max(width, minHit),
            height: max(height, minHit)
        )
    }

    /// 内容相对:图顺时针 90° 后面上的点。
    static func rotateCW90(_ p: CGPoint) -> CGPoint { CGPoint(x: 1 - p.y, y: p.x) }
    static func rotateCCW90(_ p: CGPoint) -> CGPoint { CGPoint(x: p.y, y: 1 - p.x) }
    static func flipH(_ p: CGPoint) -> CGPoint { CGPoint(x: 1 - p.x, y: p.y) }
    static func flipV(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x, y: 1 - p.y) }

    static func mapped(_ annotation: Annotation, _ transform: (CGPoint) -> CGPoint) -> Annotation {
        var next = annotation
        switch annotation.kind {
        case let .text(anchor, content, sizeFraction, colorIndex):
            next.kind = .text(anchor: transform(anchor), content: content,
                              sizeFraction: sizeFraction, colorIndex: colorIndex)
        case let .stroke(points, widthLevel, colorIndex, style):
            next.kind = .stroke(points: points.map(transform), widthLevel: widthLevel,
                                colorIndex: colorIndex, style: style)
        case let .mosaic(points, widthLevel, effect):
            next.kind = .mosaic(points: points.map(transform), widthLevel: widthLevel, effect: effect)
        case let .shape(kind, from, to, widthLevel, colorIndex):
            next.kind = .shape(kind: kind, from: transform(from), to: transform(to),
                               widthLevel: widthLevel, colorIndex: colorIndex)
        }
        return next
    }
}

struct EditSnapshot: Equatable {
    var selection: CGRect
    var quarterTurns: Int
    var flipH: Bool
    var flipV: Bool
    var straighten: Double
    var annotations: [Annotation]
}
