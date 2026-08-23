import AppKit
import ImageIO

/// 缩略图生成与缓存:ImageIO 降采样解码 + NSCache,合并重复请求
final class ThumbnailProvider: @unchecked Sendable {

    static let shared = ThumbnailProvider()

    private let cache = NSCache<NSURL, NSImage>()
    private let queue: OperationQueue = {
        let q = OperationQueue()
        q.name = "pictool.thumbnails"
        q.maxConcurrentOperationCount = 2
        q.qualityOfService = .userInitiated
        return q
    }()
    private let lock = NSLock()
    private var inFlight: [NSURL: [(NSImage?) -> Void]] = [:]

    init() {
        cache.countLimit = 900
        cache.totalCostLimit = 80 * 1024 * 1024
    }

    func cachedThumbnail(for url: URL) -> NSImage? {
        cache.object(forKey: url as NSURL)
    }

    func thumbnail(for url: URL, maxPixel: CGFloat = 180, completion: @escaping @MainActor (NSImage?) -> Void) {
        if let hit = cachedThumbnail(for: url) {
            Task { @MainActor in completion(hit) }
            return
        }
        let key = url as NSURL
        lock.lock()
        inFlight[key, default: []].append { image in
            Task { @MainActor in completion(image) }
        }
        let needsStart = (inFlight[key]?.count ?? 0) == 1
        lock.unlock()
        guard needsStart else { return }

        queue.addOperation { [weak self] in
            guard let self else { return }
            let image = Self.generate(url: url, maxPixel: maxPixel)
            if let image {
                let cost = Int(image.size.width * image.size.height * 4)
                self.cache.setObject(image, forKey: key, cost: cost)
            }
            self.lock.lock()
            let waiters = self.inFlight.removeValue(forKey: key) ?? []
            self.lock.unlock()
            for waiter in waiters { waiter(image) }
        }
    }

    func asyncThumbnail(for url: URL, maxPixel: CGFloat = 180) async -> NSImage? {
        await withCheckedContinuation { cont in
            thumbnail(for: url, maxPixel: maxPixel) { cont.resume(returning: $0) }
        }
    }

    /// ImageIO 缩略图:不整图解码、自动应用 EXIF 方向
    static func generate(url: URL, maxPixel: CGFloat) -> NSImage? {
        let srcOpts: [CFString: Any] = [kCGImageSourceShouldCache: false]
        guard let source = CGImageSourceCreateWithURL(url as CFURL, srcOpts as CFDictionary) else { return nil }
        // IfAbsent: JPEG/RAW 优先用内嵌预览,侧栏 180px 足够且远快于整图解码
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageIfAbsent: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceShouldCache: false,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }
}
