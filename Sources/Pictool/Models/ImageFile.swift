import Foundation
import UniformTypeIdentifiers

struct ImageFile: Identifiable, Hashable {
    let id: URL
    var url: URL { id }
    var name: String { id.lastPathComponent }
}

/// 图片发现与排序(纯逻辑,便于单元测试)
enum ImageDiscovery {

    /// ImageIO 可解码格式的常见扩展名(快速路径;未列出的再走 UTType 判定)
    static let knownExtensions: Set<String> = [
        // 日常格式
        "jpg", "jpeg", "jpe", "png", "gif", "heic", "heif", "heics", "avif", "avis",
        "webp", "jxl", "jp2", "j2k", "jpf", "tif", "tiff", "bmp", "ico", "icns",
        // 专业/工程格式
        "psd", "exr", "tga", "pbm", "pgm", "ppm", "pnm", "pict", "pct", "sgi",
        "dds", "hdr", "pic", "mpo", "cur",
        // 相机 RAW
        "cr2", "cr3", "crw", "nef", "nrw", "arw", "srf", "sr2", "raf", "rw2",
        "raw", "dng", "orf", "3fr", "fff", "iiq", "rwl", "x3f", "pef", "srw",
        "kdc", "dcr", "mos", "mrw", "erf", "mef",
    ]

    static func isImageFile(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        guard !ext.isEmpty else { return false }
        if knownExtensions.contains(ext) { return true }
        return UTType(filenameExtension: ext)?.conforms(to: .image) == true
    }

    /// 自然排序:img2 排在 img10 前(本地化标准比较,兼顾数字与中文)
    static func naturalLess(_ a: String, _ b: String) -> Bool {
        a.localizedStandardCompare(b) == .orderedAscending
    }

    static func sortedByName(_ urls: [URL]) -> [URL] {
        urls.sorted { naturalLess($0.lastPathComponent, $1.lastPathComponent) }
    }

    /// 列出文件夹内的图片(不递归、跳过隐藏文件)
    static func images(in folder: URL) -> [ImageFile] {
        guard let items = try? FileManager.default.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        return items
            .filter { url in
                // 目录(如 .app bundle、Photos Library)一律排除;isImageFile 只看扩展名/UTI,
                // 不做 IO,不会误伤同名无扩展名的图片文件
                if (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                    return false
                }
                let values = try? url.resourceValues(forKeys: [.isRegularFileKey])
                return values?.isRegularFile == true && isImageFile(url)
            }
            .sorted { naturalLess($0.lastPathComponent, $1.lastPathComponent) }
            .map { ImageFile(id: $0) }
    }

    static func subfolders(in folder: URL) -> [URL] {
        guard let items = try? FileManager.default.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        return items
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true }
            .sorted { naturalLess($0.lastPathComponent, $1.lastPathComponent) }
    }
}
