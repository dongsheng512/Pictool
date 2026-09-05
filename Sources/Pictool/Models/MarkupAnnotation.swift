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
        /// 锚点为文字块左上角(归一化,原点图片左上)
        case text(anchor: CGPoint, content: String, sizeLevel: Int, colorIndex: Int)
        case stroke(points: [CGPoint], widthLevel: Int, colorIndex: Int)
        /// 笔迹 = 效果蒙版;effect 决定蒙版下显示像素化还是模糊底图
        case mosaic(points: [CGPoint], widthLevel: Int, effect: MosaicEffect)
    }
}

enum EditTool: String, CaseIterable, Identifiable, Sendable {
    case crop, text, brush, mosaic, eraser
    var id: String { rawValue }
    var label: String {
        switch self {
        case .crop: "裁切"
        case .text: "文字"
        case .brush: "画笔"
        case .mosaic: "马赛克"
        case .eraser: "橡皮"
        }
    }
    var systemImage: String {
        switch self {
        case .crop: "crop"
        case .text: "character.cursor.ibeam"
        case .brush: "paintbrush.pointed"
        case .mosaic: "squareshape.split.3x3"
        case .eraser: "eraser"
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
    static let strokeWidths: [CGFloat] = [0.004, 0.008, 0.016]
    static let mosaicWidths: [CGFloat] = [0.035, 0.060, 0.100]
    static let pixelateBlocks: [CGFloat] = [0.012, 0.022, 0.038]
    static let blurRadii: [CGFloat] = [0.006, 0.012, 0.022]

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

    /// 笔迹(折线)是否覆盖某点:容差取线宽一半,另留固定小量便于点选细线
    static func stroke(_ points: [CGPoint], contains point: CGPoint, widthFraction: CGFloat) -> Bool {
        guard points.count > 1 else {
            guard let only = points.first else { return false }
            return distance(point, segment: only, only) <= 0.012
        }
        let tolerance = max(widthFraction / 2, 0.004) + 0.006
        for i in 1..<points.count {
            if distance(point, segment: points[i - 1], points[i]) <= tolerance { return true }
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
    static func textHitRect(anchor: CGPoint, content: String, sizeLevel: Int,
                            imageSize: CGSize) -> CGRect {
        let fraction = MarkPalette.fraction(MarkPalette.textSizes, level: sizeLevel)
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
        case let .text(anchor, content, sizeLevel, colorIndex):
            next.kind = .text(anchor: transform(anchor), content: content,
                              sizeLevel: sizeLevel, colorIndex: colorIndex)
        case let .stroke(points, widthLevel, colorIndex):
            next.kind = .stroke(points: points.map(transform), widthLevel: widthLevel,
                                colorIndex: colorIndex)
        case let .mosaic(points, widthLevel, effect):
            next.kind = .mosaic(points: points.map(transform), widthLevel: widthLevel, effect: effect)
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
