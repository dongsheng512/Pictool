import AppKit
import ImageIO
import UniformTypeIdentifiers

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

    /// 选区夹取到 0...1,并保证最小尺寸
    static func clampedNormalized(_ rect: CGRect, minSize: CGFloat) -> CGRect {
        var r = rect
        r.size.width = max(r.size.width, minSize)
        r.size.height = max(r.size.height, minSize)
        r.origin.x = min(max(0, r.origin.x), 1 - r.size.width)
        r.origin.y = min(max(0, r.origin.y), 1 - r.size.height)
        return r
    }
}

enum CropRatio: String, CaseIterable, Identifiable {
    case free = "自由"
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
