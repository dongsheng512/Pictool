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

    /// 像素空间的宽高比 → 归一化空间的宽高比。
    ///
    /// 选区存的是 0...1 归一化坐标,而比例预设(1:1 / 16:9 …)说的是**像素**宽高比。
    /// 归一化矩形 (w, h) 对应的像素尺寸是 (w·W, h·H),要让像素比等于 `aspect`,
    /// 归一化比必须是 `aspect·H/W = aspect / imageAspect`。
    ///
    /// 漏掉这一步的后果(实测):16:9 的整图选区归一化是 1:1,被判成「不合 16:9」,
    /// 手柄只要动 1% 选区高度就从 1.000 塌到 0.557——也就是「一点就缩小一半」。
    static func normalizedAspect(_ aspect: CGFloat, imageAspect: CGFloat) -> CGFloat {
        guard imageAspect > 0, imageAspect.isFinite else { return aspect }
        return aspect / imageAspect
    }

    /// 比例约束下的尺寸求解。
    /// - 边手柄:被拖的那一轴驱动,另一轴按比例跟随。
    /// - 角手柄:宽度驱动 / 高度驱动各算一次,**取较大的那个**。
    ///   只取内接的较小解时,沿单一轴拖动会完全没反应(另一轴一直卡住),手感像卡死。
    static func lockedSize(free: CGRect, base: CGRect, handle: CropHandle,
                           aspect: CGFloat, minSize: CGFloat) -> (width: CGFloat, height: CGFloat) {
        switch handle {
        case .move:
            return (base.width, base.height)
        case .top, .bottom:
            let height = max(free.height, minSize)
            return (height * aspect, height)
        case .left, .right:
            let width = max(free.width, minSize)
            return (width, width / aspect)
        default:
            let byWidth = max(free.width, minSize)
            let byHeight = max(free.height, minSize) * aspect
            let width = max(byWidth, byHeight)
            return (width, width / aspect)
        }
    }

    /// 比例约束下求解选区。
    /// - Parameters:
    ///   - free: 未套比例、按拖动位移直接得到的矩形
    ///   - base: 本次拖动开始时的选区(锚点来源)
    ///   - handle: 被拖动的部位
    ///   - aspect: 目标宽高比(width / height),**像素空间**
    ///   - imageAspect: 图片自身像素宽高比。选区在归一化空间,比例在像素空间,
    ///     必须先经 `normalizedAspect` 折算,否则宽幅图上选区会被瞬间压扁
    ///   - minSize: 归一化最小边长
    static func ratioLockedRect(free: CGRect, base: CGRect, handle: CropHandle,
                                aspect: CGFloat, imageAspect: CGFloat = 1,
                                minSize: CGFloat) -> CGRect {
        let floor = min(max(minSize, 0), 1)
        let ratio = normalizedAspect(aspect, imageAspect: imageAspect)
        guard ratio > 0, ratio.isFinite else {
            return clampedNormalized(free, minSize: floor)
        }

        let (axKind, ayKind) = anchor(of: handle)
        let anchorX = anchorValue(axKind, min: base.minX, max: base.maxX)
        let anchorY = anchorValue(ayKind, min: base.minY, max: base.maxY)

        let availW = available(axKind, anchor: anchorX)
        let availH = available(ayKind, anchor: anchorY)
        guard availW > 0, availH > 0 else {
            return clampedNormalized(base, minSize: floor)
        }

        // 由被拖动的那一维决定尺寸,另一维按比例跟随
        var (width, height) = lockedSize(free: free, base: base, handle: handle,
                                         aspect: ratio, minSize: floor)

        // 沿锚定方向的可用空间有限时等比收缩,保持比例
        if width > availW || height > availH {
            let k = min(availW / width, availH / height)
            width *= k
            height *= k
        }
        // 最小尺寸:任一维不足就整体放大(直接各自取 max 会破坏比例),再夹一次可用空间
        let grow = max(floor / max(width, .leastNonzeroMagnitude),
                       floor / max(height, .leastNonzeroMagnitude))
        if grow > 1 {
            width *= grow
            height *= grow
            if width > availW || height > availH {
                let k = min(availW / width, availH / height)
                width *= k
                height *= k
            }
        }

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

    /// 目标宽高比(width / height,**像素空间**);nil = 不锁形状,自由拖动。
    /// 「原始」跟随图片自身比例;自定义解析不出(≤0)时返回 nil,按自由处理。
    /// 「自由」必须返回 nil:比例一旦非 nil,拖动时另一轴就会被比例拖着走,形状改不了。
    func aspect(imageAspect: CGFloat, customAspect: CGFloat?) -> CGFloat? {
        switch self {
        case .free: return nil
        case .original: return imageAspect
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
    /// 管线:解码 → 变换 → 烙印标记(整张变换图)→ 裁切 → 降采样 → 水印 → 编码。
    /// 标记坐标是变换后整图的归一化 0...1;裁掉的部分连同框外笔迹一起丢掉。
    static func encode(sourceURL: URL,
                       normalizedRect: CGRect,
                       format: CropFormat,
                       quality: Double,
                       quarterTurns: Int = 0,
                       flipH: Bool = false,
                       flipV: Bool = false,
                       straightenDegrees: Double = 0,
                       maxLongestSide: Int? = nil,
                       includeGPS: Bool = true,
                       annotations: [Annotation] = [],
                       watermark: WatermarkSettings? = nil) throws -> Data {
        let full = try ImageLoader.decodeFullCGImage(url: sourceURL)
        var canvas = CropTransform.apply(
            to: full, quarterTurns: quarterTurns, flipH: flipH, flipV: flipV,
            straightenDegrees: straightenDegrees
        )
        if !annotations.isEmpty {
            let size = CGSize(width: canvas.width, height: canvas.height)
            if let ctx = CGContext(
                data: nil, width: canvas.width, height: canvas.height, bitsPerComponent: 8, bytesPerRow: 0,
                space: canvas.colorSpace ?? CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
            ) {
                ctx.draw(canvas, in: CGRect(origin: .zero, size: size))
                AnnotationRenderer.draw(annotations, in: ctx, canvasSize: size, base: canvas)
                if let stamped = ctx.makeImage() { canvas = stamped }
            }
        }
        let rect = CropMath.pixelRect(
            normalized: normalizedRect,
            pixelSize: CGSize(width: canvas.width, height: canvas.height)
        )
        guard let cropped = canvas.cropping(to: rect), rect.width > 0, rect.height > 0 else {
            throw CropError.decodeFailed
        }
        let output = CropTransform.downscaled(cropped, longestSide: maxLongestSide ?? 0)

        // 水印烙在最終输出像素上(裁切/缩放之后),九宫格与平铺都相对最终画幅
        var finalOutput = output
        if let watermark, watermark.enabled, watermark.hasContent {
            let size = CGSize(width: output.width, height: output.height)
            if let ctx = CGContext(
                data: nil, width: output.width, height: output.height, bitsPerComponent: 8,
                bytesPerRow: 0, space: output.colorSpace ?? CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
            ) {
                ctx.draw(output, in: CGRect(origin: .zero, size: size))
                WatermarkRenderer.draw(watermark, in: ctx, canvasSize: size)
                if let composed = ctx.makeImage() { finalOutput = composed }
            }
        }

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
        CGImageDestinationAddImage(dest, finalOutput, properties as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw CropError.encodeFailed }
        return data as Data
    }
}
