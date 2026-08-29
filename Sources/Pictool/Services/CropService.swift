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
    case threeBy2 = "3:2"
    case fiveBy4 = "5:4"
    case custom = "自定义"
    var id: String { rawValue }

    /// 目标宽高比(width / height)。自由/原始跟随图片自身比例;
    /// 自定义由调用方解析输入框给出,解析不出(≤0)时返回 nil,按自由处理。
    func aspect(imageAspect: CGFloat, customAspect: CGFloat?) -> CGFloat? {
        switch self {
        case .free, .original: return imageAspect
        case .square: return 1
        case .fourBy3: return 4.0 / 3.0
        case .threeBy4: return 3.0 / 4.0
        case .sixteenBy9: return 16.0 / 9.0
        case .nineBy16: return 9.0 / 16.0
        case .threeBy2: return 3.0 / 2.0
        case .fiveBy4: return 5.0 / 4.0
        case .custom: return customAspect
        }
    }

    /// 预设比例能否交换横竖(自由/原始/1:1 无意义)
    var supportsSwap: Bool {
        switch self {
        case .free, .original, .square: return false
        default: return true
        }
    }

    /// 从 "4:3" 这类标签解析出 (w, h);解析不出返回 nil
    var labelPair: (w: Int, h: Int)? {
        let parts = rawValue.split(separator: ":")
        guard parts.count == 2, let w = Int(parts[0]), let h = Int(parts[1]) else { return nil }
        return (w, h)
    }
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

    /// 扩展名与格式严格对应时返回格式;否则 nil(覆盖原图只允许同格式写回,
    /// 避免把 .gif 覆盖成 PNG 内容却挂着 .gif 扩展名)
    static func exactSourceExt(_ ext: String) -> CropFormat? {
        switch ext.lowercased() {
        case "png": return .png
        case "jpg", "jpeg": return .jpeg
        case "heic": return .heic
        case "tif", "tiff": return .tiff
        default: return nil
        }
    }
}

/// 几何变换(纯函数,单测覆盖):四分旋转、翻转、拉直、按最长边降采样。
/// 全部输出"已经摆正"的位图,选区归一化坐标始终基于变换后的图幅。
enum CropTransform {

    /// 奇数档旋转会交换宽高(选区所在坐标系的尺寸)
    static func transformedSize(width: Int, height: Int, quarterTurns: Int) -> CGSize {
        (((quarterTurns % 2) + 2) % 2 == 1)
            ? CGSize(width: height, height: width)
            : CGSize(width: width, height: height)
    }

    /// 拉直所需的最小放大倍数:旋转 θ 后位图包围盒为 (w·cos+h·sin, w·sin+h·cos),
    /// 要让原尺寸画框内没有空角,需按包围盒与画框的比值放大。
    static func coverScale(degrees: Double, width: CGFloat, height: CGFloat) -> CGFloat {
        let rad = abs(degrees) * .pi / 180
        guard rad > 0.0001, width > 0, height > 0 else { return 1 }
        let s = CGFloat(sin(rad)), c = CGFloat(cos(rad))
        return max((width * c + height * s) / width,
                   (width * s + height * c) / height)
    }

    /// 依次应用四分旋转(顺时针为正)→ 翻转 → 拉直。各步独立成图,最多三次绘制,
    /// 导出全尺寸时也在毫秒级,不值得为省两次拷贝写成单一仿射。
    static func apply(to image: CGImage, quarterTurns: Int, flipH: Bool, flipV: Bool,
                      straightenDegrees: Double) -> CGImage {
        var current = image
        let turns = ((quarterTurns % 4) + 4) % 4
        if turns != 0, let rotated = rotateQuarter(current, turns) { current = rotated }
        if flipH || flipV, let flipped = flipped(current, horizontal: flipH, vertical: flipV) {
            current = flipped
        }
        if abs(straightenDegrees) > 0.0001,
           let straightened = straightened(current, degrees: straightenDegrees) {
            current = straightened
        }
        return current
    }

    /// 按最长边降采样;已不超长或参数非法时原样返回
    static func downscaled(_ image: CGImage, longestSide: Int) -> CGImage {
        let longest = max(image.width, image.height)
        guard longestSide > 0, longest > longestSide else { return image }
        let k = CGFloat(longestSide) / CGFloat(longest)
        let outW = max(1, Int((CGFloat(image.width) * k).rounded()))
        let outH = max(1, Int((CGFloat(image.height) * k).rounded()))
        guard let ctx = makeContext(width: outW, height: outH, colorSpace: image.colorSpace ?? CGColorSpaceCreateDeviceRGB()) else {
            return image
        }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: outW, height: outH))
        return ctx.makeImage() ?? image
    }

    // MARK: 私有

    private static func makeContext(width: Int, height: Int, colorSpace: CGColorSpace) -> CGContext? {
        CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                  space: colorSpace,
                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
    }

    /// turns = 顺时针 90° 的次数。方向有像素级单测锁死(左上红块转向验证)。
    private static func rotateQuarter(_ image: CGImage, _ turns: Int) -> CGImage? {
        let w = image.width, h = image.height
        let out = transformedSize(width: w, height: h, quarterTurns: turns)
        guard let ctx = makeContext(width: Int(out.width), height: Int(out.height),
                                    colorSpace: image.colorSpace ?? CGColorSpaceCreateDeviceRGB()) else { return nil }
        switch turns {
        case 1:  ctx.translateBy(x: out.width, y: 0); ctx.rotate(by: .pi / 2)
        case 2:  ctx.translateBy(x: out.width, y: out.height); ctx.rotate(by: .pi)
        case 3:  ctx.translateBy(x: 0, y: out.height); ctx.rotate(by: -.pi / 2)
        default: break
        }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()
    }

    private static func flipped(_ image: CGImage, horizontal: Bool, vertical: Bool) -> CGImage? {
        let w = image.width, h = image.height
        guard let ctx = makeContext(width: w, height: h,
                                    colorSpace: image.colorSpace ?? CGColorSpaceCreateDeviceRGB()) else { return nil }
        ctx.translateBy(x: horizontal ? CGFloat(w) : 0, y: vertical ? CGFloat(h) : 0)
        ctx.scaleBy(x: horizontal ? -1 : 1, y: vertical ? -1 : 1)
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()
    }

    /// 拉直:围绕中心旋转并按 coverScale 放大,输出与输入同尺寸(空角被裁掉)。
    /// 正角度 = 显示上顺时针(CG 上下文 y 轴向上,渲染时上下翻转,旋转方向随之反转)。
    private static func straightened(_ image: CGImage, degrees: Double) -> CGImage? {
        let w = image.width, h = image.height
        let scale = coverScale(degrees: degrees, width: CGFloat(w), height: CGFloat(h))
        guard scale > 1, let ctx = makeContext(width: w, height: h,
                                               colorSpace: image.colorSpace ?? CGColorSpaceCreateDeviceRGB()) else { return nil }
        ctx.translateBy(x: CGFloat(w) / 2, y: CGFloat(h) / 2)
        ctx.rotate(by: CGFloat(degrees * .pi / 180))
        ctx.scaleBy(x: scale, y: scale)
        ctx.draw(image, in: CGRect(x: -CGFloat(w) / 2, y: -CGFloat(h) / 2,
                                   width: CGFloat(w), height: CGFloat(h)))
        return ctx.makeImage()
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

    /// 返回编码后的图片数据,由调用方负责保存面板与写盘。
    /// 管线:解码全尺寸 → 变换(旋转/翻转/拉直)→ 按归一化选区裁切 → 可选降采样 → 编码。
    /// 选区归一化坐标基于变换后的图幅,与预览一致。
    static func encode(sourceURL: URL,
                       normalizedRect: CGRect,
                       format: CropFormat,
                       quality: Double,
                       quarterTurns: Int = 0,
                       flipH: Bool = false,
                       flipV: Bool = false,
                       straightenDegrees: Double = 0,
                       maxLongestSide: Int? = nil,
                       includeGPS: Bool = true) throws -> Data {
        let full = try ImageLoader.decodeFullCGImage(url: sourceURL)
        let transformed = CropTransform.apply(
            to: full, quarterTurns: quarterTurns, flipH: flipH, flipV: flipV,
            straightenDegrees: straightenDegrees
        )
        let rect = CropMath.pixelRect(
            normalized: normalizedRect,
            pixelSize: CGSize(width: transformed.width, height: transformed.height)
        )
        guard let cropped = transformed.cropping(to: rect), rect.width > 0, rect.height > 0 else {
            throw CropError.decodeFailed
        }
        let output = CropTransform.downscaled(cropped, longestSide: maxLongestSide ?? 0)

        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(
            data, format.uti as CFString, 1, nil
        ) else { throw CropError.encodeFailed }

        var properties: [CFString: Any] = [:]
        properties[kCGImagePropertyOrientation] = 1  // 像素已按 EXIF 方向摆正
        if format.isLossy {
            properties[kCGImageDestinationLossyCompressionQuality] = quality
        }
        // 携带原 EXIF / IPTC;GPS 按隐私开关决定是否带出
        if let source = CGImageSourceCreateWithURL(sourceURL as CFURL, nil),
           let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] {
            for key in [kCGImagePropertyExifDictionary, kCGImagePropertyIPTCDictionary] {
                if let value = props[key] { properties[key] = value }
            }
            if includeGPS, let gps = props[kCGImagePropertyGPSDictionary] {
                properties[kCGImagePropertyGPSDictionary] = gps
            }
        }
        CGImageDestinationAddImage(dest, output, properties as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw CropError.encodeFailed }
        return data as Data
    }
}
