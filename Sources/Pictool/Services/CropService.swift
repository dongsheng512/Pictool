import AppKit
import ImageIO
import UniformTypeIdentifiers

/// 选区被拖动的部位。角手柄同时驱动两个轴,边手柄只驱动一个轴,整体拖移不改变尺寸。
enum CropHandle: String, CaseIterable {
    case move, topLeft, topRight, bottomLeft, bottomRight, top, bottom, left, right
}

/// 某一轴上的锚定方式:贴最小边、贴最大边,或保持中心不动。
/// 拖上/下边时水平方向应锚中心;拖左/右边时垂直方向应锚中心——
/// 早期实现把中心当成了 max 处理,导致选区每帧横向/纵向跳半个身位。
enum CropAnchor {
    case min, max, center
}

/// 裁切坐标换算(纯函数,单元测试覆盖)
enum CropMath {

    /// 归一化选区(0...1,原点在图片左上,与 CGImage 像素行序一致)→ 整数像素矩形,夹取到图像范围内
    static func pixelRect(normalized: CGRect, pixelSize: CGSize) -> CGRect {
        let w = max(1, Int(pixelSize.width.rounded()))
        let h = max(1, Int(pixelSize.height.rounded()))
        let px = min(max(0, Int((normalized.minX * CGFloat(w)).rounded())), w - 1)
        let py = min(max(0, Int((normalized.minY * CGFloat(h)).rounded())), h - 1)
        let pw = min(max(1, Int((normalized.width * CGFloat(w)).rounded())), w - px)
        let ph = min(max(1, Int((normalized.height * CGFloat(h)).rounded())), h - py)
        return CGRect(x: px, y: py, width: pw, height: ph)
    }

    /// 选区夹取到 0...1,并保证最小尺寸。
    /// 尺寸也要夹到 1 以内:否则 `1 - size` 变负,origin 会被推到负区间,选区整体跑出图片。
    static func clampedNormalized(_ rect: CGRect, minSize: CGFloat) -> CGRect {
        var r = rect
        let floor = min(max(minSize, 0), 1)
        r.size.width = min(max(r.size.width, floor), 1)
        r.size.height = min(max(r.size.height, floor), 1)
        r.origin.x = min(max(0, r.origin.x), 1 - r.size.width)
        r.origin.y = min(max(0, r.origin.y), 1 - r.size.height)
        return r
    }

    // MARK: 比例约束

    /// 各部位的锚点:拖动边的对侧固定;单轴拖动时另一轴保持中心不动;整体拖移两轴都锚中心。
    static func anchor(of handle: CropHandle) -> (x: CropAnchor, y: CropAnchor) {
        switch handle {
        case .move:        return (.center, .center)
        case .topLeft:     return (.max, .max)
        case .topRight:    return (.min, .max)
        case .bottomLeft:  return (.max, .min)
        case .bottomRight: return (.min, .min)
        case .top:         return (.center, .max)
        case .bottom:      return (.center, .min)
        case .left:        return (.max, .center)
        case .right:       return (.min, .center)
        }
    }

    /// 锚点在轴上的具体坐标
    static func anchorValue(_ kind: CropAnchor, min: CGFloat, max: CGFloat) -> CGFloat {
        switch kind {
        case .min:    return min
        case .max:    return max
        case .center: return (min + max) / 2
        }
    }

    /// 从锚点沿锚定方向最多能铺开多少
    static func available(_ kind: CropAnchor, anchor: CGFloat) -> CGFloat {
        let raw: CGFloat
        switch kind {
        case .min:    raw = 1 - anchor                    // 向右铺到 1
        case .max:    raw = anchor                        // 向左铺到 0
        case .center: raw = 2 * min(anchor, 1 - anchor)   // 向两侧各铺到较近的边界
        }
        return max(0, raw)
    }

    /// 按锚定方式,由锚点与尺寸反推原点
    static func placement(_ kind: CropAnchor, anchor: CGFloat, size: CGFloat) -> CGFloat {
        switch kind {
        case .min:    return anchor
        case .max:    return anchor - size
        case .center: return anchor - size / 2
        }
    }

    /// 比例约束下求解选区。
    /// - Parameters:
    ///   - free: 未套比例、按拖动位移直接得到的矩形
    ///   - base: 本次拖动开始时的选区(锚点来源)
    ///   - handle: 被拖动的部位
    ///   - aspect: 目标宽高比(width / height)
    ///   - minSize: 归一化最小边长
    static func ratioLockedRect(free: CGRect, base: CGRect, handle: CropHandle,
                                aspect: CGFloat, minSize: CGFloat) -> CGRect {
        let floor = min(max(minSize, 0), 1)
        guard aspect > 0 else { return clampedNormalized(free, minSize: floor) }

        let (axKind, ayKind) = anchor(of: handle)
        let anchorX = anchorValue(axKind, min: base.minX, max: base.maxX)
        let anchorY = anchorValue(ayKind, min: base.minY, max: base.maxY)

        // 由被拖动的那一维决定尺寸,另一维按比例跟随
        var width: CGFloat = 0
        var height: CGFloat = 0
        switch handle {
        case .move:
            width = base.width
            height = base.height
        case .top, .bottom:
            height = max(free.height, floor)
            width = height * aspect
        case .left, .right:
            width = max(free.width, floor)
            height = width / aspect
        default:
            // 角:先按宽度算,若高度超出则改以高度为准(收缩到自由矩形内)
            width = max(free.width, floor)
            height = width / aspect
            if height > free.height {
                height = max(free.height, floor)
                width = height * aspect
            }
        }

        // 沿锚定方向的可用空间有限时等比收缩,保持比例
        let availW = available(axKind, anchor: anchorX)
        let availH = available(ayKind, anchor: anchorY)
        if availW <= 0 || availH <= 0 {
            return clampedNormalized(base, minSize: floor)
        }
        if width > availW || height > availH {
            let k = min(availW / width, availH / height)
            width *= k
            height *= k
        }
        width = max(width, floor)
        height = max(height, floor)

        let x = placement(axKind, anchor: anchorX, size: width)
        let y = placement(ayKind, anchor: anchorY, size: height)
        return clampedNormalized(CGRect(x: x, y: y, width: width, height: height), minSize: floor)
    }
}

enum CropRatio: String, CaseIterable, Identifiable {
    case free = "自由"
    case original = "原始"
    case square = "1:1"
    case fourBy3 = "4:3"
    case threeBy4 = "3:4"
    case sixteenBy9 = "16:9"
    case nineBy16 = "9:16"
    var id: String { rawValue }
}

enum CropFormat: String, CaseIterable, Identifiable {
    case png = "PNG"
    case jpeg = "JPEG"
    case heic = "HEIC"
    case tiff = "TIFF"
    var id: String { rawValue }
    var uti: String {
        switch self {
        case .png: return UTType.png.identifier
        case .jpeg: return UTType.jpeg.identifier
        case .heic: return "public.heic"
        case .tiff: return UTType.tiff.identifier
        }
    }
    var fileExtension: String {
        switch self {
        case .png: return "png"
        case .jpeg: return "jpg"
        case .heic: return "heic"
        case .tiff: return "tif"
        }
    }
    var isLossy: Bool { self == .jpeg || self == .heic }

    /// 依据源文件扩展名给出默认导出格式(源格式可编码则沿用,否则 PNG)
    static func `default`(forSourceExt ext: String) -> CropFormat {
        switch ext.lowercased() {
        case "jpg", "jpeg": return .jpeg
        case "heic": return .heic
        case "tif", "tiff": return .tiff
        default: return .png
        }
    }
}

enum CropError: LocalizedError {
    case decodeFailed, encodeFailed
    var errorDescription: String? {
        switch self {
        case .decodeFailed: return "无法解码原图(裁切需要完整图像数据)"
        case .encodeFailed: return "图像编码失败"
        }
    }
}

/// 裁切 + 编码导出(尽量保留原 EXIF;方向已在解码时摆正,导出时重置 orientation)
enum CropService {

    /// 返回编码后的图片数据,由调用方负责保存面板与写盘
    static func encode(sourceURL: URL,
                       normalizedRect: CGRect,
                       format: CropFormat,
                       quality: Double) throws -> Data {
        let facts = ImageLoader.facts(of: sourceURL)
        let pixelSize = CGSize(width: facts.pixelWidth, height: facts.pixelHeight)
        guard pixelSize.width > 1, pixelSize.height > 1 else { throw CropError.decodeFailed }

        let rect = CropMath.pixelRect(normalized: normalizedRect, pixelSize: pixelSize)
        let full = try ImageLoader.decodeFullCGImage(url: sourceURL)
        guard let cropped = full.cropping(to: rect), rect.width > 0, rect.height > 0 else {
            throw CropError.decodeFailed
        }

        let output = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(
            output, format.uti as CFString, 1, nil
        ) else { throw CropError.encodeFailed }

        var properties: [CFString: Any] = [:]
        properties[kCGImagePropertyOrientation] = 1  // 像素已按 EXIF 方向摆正
        if format.isLossy {
            properties[kCGImageDestinationLossyCompressionQuality] = quality
        }
        // 携带原 EXIF / GPS(无方向语义的部分)
        if let source = CGImageSourceCreateWithURL(sourceURL as CFURL, nil),
           let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] {
            for key in [kCGImagePropertyExifDictionary, kCGImagePropertyGPSDictionary,
                        kCGImagePropertyIPTCDictionary] {
                if let value = props[key] { properties[key] = value }
            }
        }
        CGImageDestinationAddImage(dest, cropped, properties as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw CropError.encodeFailed }
        return output as Data
    }
}
