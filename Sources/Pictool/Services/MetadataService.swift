import Foundation
import ImageIO
import UniformTypeIdentifiers

struct InfoRow: Identifiable {
    let id = UUID()
    let label: String
    let value: String
}

struct InfoSection: Identifiable {
    let id = UUID()
    let title: String
    let rows: [InfoRow]
}

struct ImageInfo {
    let sections: [InfoSection]
    var summaryText: String {
        sections
            .map { sec in
                "【\(sec.title)】\n" + sec.rows.map { "\($0.label):\($0.value)" }.joined(separator: "\n")
            }
            .joined(separator: "\n\n")
    }
}

/// CGImageSource 属性解析 → 信息面板数据(文件 / 图像 / EXIF / GPS)
enum MetadataService {

    static func formatName(of typeID: String?) -> String {
        guard let typeID else { return "未知" }
        switch typeID {
        case "public.jpeg": return "JPEG"
        case "public.png": return "PNG"
        case "com.compuserve.gif": return "GIF"
        case "public.heic": return "HEIC"
        case "public.heif": return "HEIF"
        case "public.heics": return "HEIC(动画)"
        case "public.avif": return "AVIF"
        case "public.avis": return "AVIF(动画)"
        case "org.webmproject.webp": return "WebP"
        case "public.jpeg-xl": return "JPEG XL"
        case "public.tiff": return "TIFF"
        case "com.microsoft.bmp": return "BMP"
        case "com.microsoft.ico": return "ICO"
        case "com.apple.icns": return "ICNS"
        case "com.adobe.photoshop-image": return "PSD"
        case "com.ilm.openexr-image": return "OpenEXR"
        case "public.jpeg-2000": return "JPEG 2000"
        default:
            if let ut = UTType(typeID), let ext = ut.preferredFilenameExtension {
                return ext.uppercased()
            }
            return typeID
        }
    }

    static func colorModelName(_ raw: String) -> String {
        switch raw {
        case "RGB": return "RGB"
        case "Gray": return "灰度"
        case "CMYK": return "CMYK"
        case "L*": return "L*"
        case "XYZ": return "XYZ"
        case "YCbCr": return "YCbCr"
        default: return raw
        }
    }

    static func info(for url: URL) -> ImageInfo {
        var sections: [InfoSection] = []
        let df = DateFormatter()
        df.dateStyle = .medium
        df.timeStyle = .short

        // ---- 文件 ----
        var fileRows = [InfoRow(label: "文件名", value: url.lastPathComponent)]
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .creationDateKey, .contentModificationDateKey])
        if let size = values?.fileSize {
            fileRows.append(InfoRow(label: "大小", value: ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)))
        }
        if let created = values?.creationDate {
            fileRows.append(InfoRow(label: "创建时间", value: df.string(from: created)))
        }
        if let modified = values?.contentModificationDate {
            fileRows.append(InfoRow(label: "修改时间", value: df.string(from: modified)))
        }
        fileRows.append(InfoRow(label: "路径", value: url.path))
        sections.append(InfoSection(title: "文件", rows: fileRows))

        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            sections.append(InfoSection(title: "图像", rows: [InfoRow(label: "错误", value: "无法读取图像数据")]))
            return ImageInfo(sections: sections)
        }
        let props = (CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]) ?? [:]
        let frameCount = CGImageSourceGetCount(source)

        // ---- 图像 ----
        var imgRows: [InfoRow] = []
        imgRows.append(InfoRow(label: "格式", value: formatName(of: CGImageSourceGetType(source) as String?)))
        if let w = props[kCGImagePropertyPixelWidth] as? Int, let h = props[kCGImagePropertyPixelHeight] as? Int {
            imgRows.append(InfoRow(label: "像素尺寸", value: "\(w) × \(h)"))
        }
        if frameCount > 1 {
            imgRows.append(InfoRow(label: "帧数", value: "\(frameCount)"))
        }
        if let dpiW = props[kCGImagePropertyDPIWidth] as? Int, dpiW > 0 {
            let dpiH = props[kCGImagePropertyDPIHeight] as? Int ?? dpiW
            imgRows.append(InfoRow(label: "DPI", value: "\(dpiW) × \(dpiH)"))
        }
        if let cm = props[kCGImagePropertyColorModel] as? String {
            imgRows.append(InfoRow(label: "色彩模式", value: colorModelName(cm)))
        }
        if let depth = props[kCGImagePropertyDepth] as? Int {
            imgRows.append(InfoRow(label: "位深", value: "\(depth) 位/通道"))
        }
        if let alpha = props[kCGImagePropertyHasAlpha] as? Bool, alpha {
            imgRows.append(InfoRow(label: "透明通道", value: "有"))
        }
        if let profile = props[kCGImagePropertyProfileName] as? String {
            imgRows.append(InfoRow(label: "色彩配置", value: profile))
        }
        sections.append(InfoSection(title: "图像", rows: imgRows))

        // ---- 拍摄信息(EXIF / TIFF) ----
        let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
        let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any]
        var exifRows: [InfoRow] = []
        func add(_ label: String, _ value: String?) {
            if let value, !value.isEmpty { exifRows.append(InfoRow(label: label, value: value)) }
        }
        add("制造商", (tiff?[kCGImagePropertyTIFFMake] as? String))
        add("型号", (tiff?[kCGImagePropertyTIFFModel] as? String))
        add("镜头", (exif?[kCGImagePropertyExifLensModel] as? String))
        if let t = exif?[kCGImagePropertyExifExposureTime] as? Double {
            add("快门", t < 1 ? String(format: "1/%.0f 秒", 1 / t) : String(format: "%.1f 秒", t))
        }
        if let f = exif?[kCGImagePropertyExifFNumber] as? Double {
            add("光圈", String(format: "f/%.1f", f))
        }
        if let isos = exif?[kCGImagePropertyExifISOSpeedRatings] as? [Int], let iso = isos.first {
            add("ISO", "\(iso)")
        }
        if let fl = exif?[kCGImagePropertyExifFocalLength] as? Double {
            add("焦距", String(format: "%.0f mm", fl))
        }
        add("拍摄时间", (exif?[kCGImagePropertyExifDateTimeOriginal] as? String))
        if let program = exif?[kCGImagePropertyExifExposureProgram] as? Int {
            add("曝光程序", exposureProgramName(program))
        }
        if let flash = exif?[kCGImagePropertyExifFlash] as? Int {
            add("闪光灯", (flash & 1) == 1 ? "开启" : "关闭")
        }
        if let wb = exif?[kCGImagePropertyExifWhiteBalance] as? Int {
            add("白平衡", wb == 0 ? "自动" : "手动")
        }
        if !exifRows.isEmpty {
            sections.append(InfoSection(title: "拍摄信息", rows: exifRows))
        }

        // ---- GPS ----
        if let gps = props[kCGImagePropertyGPSDictionary] as? [CFString: Any],
           let lat = gps[kCGImagePropertyGPSLatitude] as? Double,
           let lon = gps[kCGImagePropertyGPSLongitude] as? Double {
            let latRef = gps[kCGImagePropertyGPSLatitudeRef] as? String ?? "N"
            let lonRef = gps[kCGImagePropertyGPSLongitudeRef] as? String ?? "E"
            let signedLat = latRef == "S" ? -lat : lat
            let signedLon = lonRef == "W" ? -lon : lon
            sections.append(InfoSection(title: "GPS", rows: [
                InfoRow(label: "纬度", value: String(format: "%.6f°", signedLat)),
                InfoRow(label: "经度", value: String(format: "%.6f°", signedLon)),
            ]))
        }

        return ImageInfo(sections: sections)
    }

    static func exposureProgramName(_ value: Int) -> String {
        switch value {
        case 1: return "手动"
        case 2: return "程序自动"
        case 3: return "光圈优先"
        case 4: return "快门优先"
        case 5: return "创意自动"
        case 6: return "运动模式"
        case 7: return "人像模式"
        case 8: return "风景模式"
        default: return "程序 \(value)"
        }
    }
}
