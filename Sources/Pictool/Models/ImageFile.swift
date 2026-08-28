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

    /// 排序用的稳定键(缺失拍摄时间时回退到修改时间)
    struct SortRecord: Equatable {
        let url: URL
        let modified: Date
        let size: Int64
        let captured: Date?
        var name: String { url.lastPathComponent }
    }

    static func compare(_ a: SortRecord, _ b: SortRecord, by preference: ImageSortPreference) -> Bool {
        let nameLess = naturalLess(a.name, b.name)
        let ascending = preference.direction == .ascending
        func ordered<T: Comparable>(_ lhs: T, _ rhs: T) -> Bool {
            if lhs == rhs { return nameLess }
            return ascending ? lhs < rhs : lhs > rhs
        }
        switch preference.key {
        case .name:
            return ascending ? nameLess : naturalLess(b.name, a.name)
        case .modified:
            return ordered(a.modified, b.modified)
        case .size:
            return ordered(a.size, b.size)
        case .captured:
            let ad = a.captured ?? a.modified
            let bd = b.captured ?? b.modified
            return ordered(ad, bd)
        }
    }

    static func sorted(_ urls: [URL], by preference: ImageSortPreference) -> [URL] {
        switch preference.key {
        case .name:
            let named = sortedByName(urls)
            return preference.direction == .ascending ? named : Array(named.reversed())
        case .modified, .size, .captured:
            return makeRecords(urls, includeCapture: preference.key == .captured)
                .sorted { compare($0, $1, by: preference) }
                .map(\.url)
        }
    }

    /// 列出文件夹内图片 URL(不排序)。拍摄时间排序请先拿 URL 再在后台 `sorted`。
    static func imageURLs(in folder: URL) -> [URL] {
        guard let items = try? FileManager.default.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey, .contentModificationDateKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        var candidates: [URL] = []
        candidates.reserveCapacity(items.count)
        let lock = NSLock()
        DispatchQueue.concurrentPerform(iterations: items.count) { i in
            let url = items[i]
            let ext = url.pathExtension.lowercased()
            let maybeImage = ext.isEmpty ? false : (knownExtensions.contains(ext) || UTType(filenameExtension: ext)?.conforms(to: .image) == true)
            if !maybeImage { return }
            if (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true { return }
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey])
            if values?.isRegularFile == true {
                lock.lock()
                candidates.append(url)
                lock.unlock()
            }
        }
        return candidates
    }

    static func imageCount(in folder: URL) -> Int {
        imageURLs(in: folder).count
    }

    private static func makeRecords(_ urls: [URL], includeCapture: Bool) -> [SortRecord] {
        var records = Array<SortRecord?>(repeating: nil, count: urls.count)
        let lock = NSLock()
        DispatchQueue.concurrentPerform(iterations: urls.count) { i in
            let url = urls[i]
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            let record = SortRecord(
                url: url,
                modified: values?.contentModificationDate ?? .distantPast,
                size: Int64(values?.fileSize ?? 0),
                captured: includeCapture ? MetadataService.captureDate(of: url) : nil
            )
            lock.lock()
            records[i] = record
            lock.unlock()
        }
        return records.compactMap { $0 }
    }

    /// 列出文件夹内的图片(不递归、跳过隐藏文件)
    /// 增量友好：先用 enumerator 快速拿 URL，再并行判文件类型，避免单线程 isDirectory 阻塞
    static func images(in folder: URL, sortedBy preference: ImageSortPreference = .default) -> [ImageFile] {
        let urls = imageURLs(in: folder)
        if preference.key == .captured {
            return sorted(urls, by: ImageSortPreference(key: .name, direction: preference.direction))
                .map { ImageFile(id: $0) }
        }
        return sorted(urls, by: preference).map { ImageFile(id: $0) }
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
