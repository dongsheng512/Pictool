import AppKit
import ImageIO
import UniformTypeIdentifiers

enum ImageLoadError: LocalizedError {
    case cannotOpen, cannotDecode
    var errorDescription: String? {
        switch self {
        case .cannotOpen: return "无法打开图片文件"
        case .cannotDecode: return "无法解码图片数据"
        }
    }
}

enum ImageLoader {

    struct SourceFacts: Sendable {
        /// 摆正后的像素尺寸(已按 EXIF 方向对调),与实际解码得到的位图一致
        var pixelWidth = 0
        var pixelHeight = 0
        var frameCount = 1
        var formatID: String?

        var maxPixel: CGFloat { CGFloat(max(pixelWidth, pixelHeight)) }
    }

    /// EXIF 方向是否让宽高对调。
    /// 5/6/7/8 表示像素矩阵被旋转 ±90° 存储,解码时 `CreateThumbnailWithTransform`
    /// 会摆正位图,于是输出的宽高是文件里存的反过来。
    static func orientationSwapsAxes(_ orientation: Int) -> Bool {
        (5...8).contains(orientation)
    }

    /// 读取顶层 EXIF 方向。ImageIO 会把 TIFF/EXIF 里的方向归一化到顶层键,
    /// 缺失时按 1(无需旋转)处理。
    static func orientation(from properties: [CFString: Any]) -> Int {
        if let value = properties[kCGImagePropertyOrientation] as? Int { return value }
        if let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any],
           let value = tiff[kCGImagePropertyTIFFOrientation] as? Int { return value }
        return 1
    }

    /// 已缓存的降采样图是否足以满足本次请求(全尺寸或覆盖请求边长 / 真实边长)
    static func cachedSatisfies(cachedMaxPixel: CGFloat?, truePixelMax: CGFloat, requestedMaxPixel: CGFloat?) -> Bool {
        if cachedMaxPixel == nil { return true }
        let cached = cachedMaxPixel!
        if cached + 0.5 >= truePixelMax { return true }
        if let requested = requestedMaxPixel {
            return cached + 0.5 >= requested
        }
        return false
    }

    /// 读取图片基本信息(不解码像素)
    static func facts(of url: URL) -> SourceFacts {
        guard let source = makeSource(url) else { return SourceFacts() }
        return facts(from: source)
    }

    /// 降采样解码(浏览用;maxPixelSize 传 nil 则全量解码)。EXIF 方向已自动摆正。
    static func decode(url: URL, maxPixelSize: CGFloat?) throws -> NSImage {
        try decodeWithFacts(url: url, maxPixelSize: maxPixelSize).image
    }

    /// 一次打开源文件同时给出像素信息与解码结果
    static func decodeWithFacts(url: URL, maxPixelSize: CGFloat?) throws -> (image: NSImage, facts: SourceFacts) {
        guard let source = makeSource(url) else { throw ImageLoadError.cannotOpen }
        let facts = facts(from: source)
        guard let cg = makeCGImage(source: source, maxPixelSize: maxPixelSize) else {
            throw ImageLoadError.cannotDecode
        }
        let image = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        return (image, facts)
    }

    /// 全尺寸 CGImage(裁切/导出/打印用),EXIF 方向已摆正(导出时需置 orientation = 1)
    static func decodeFullCGImage(url: URL) throws -> CGImage {
        guard let source = makeSource(url) else { throw ImageLoadError.cannotOpen }
        let facts = facts(from: source)
        guard facts.pixelWidth > 0, facts.pixelHeight > 0 else { throw ImageLoadError.cannotDecode }
        guard let cg = makeCGImage(source: source, maxPixelSize: facts.maxPixel) else {
            throw ImageLoadError.cannotDecode
        }
        return cg
    }

    /// 浏览解码:命中缓存则立刻返回,否则解码并写入缓存。全尺寸不进缓存。
    static func displayImage(url: URL, maxPixelSize: CGFloat) async -> (image: NSImage, facts: SourceFacts)? {
        await DisplayImageCache.shared.image(for: url, maxPixelSize: maxPixelSize)
    }

    static func cachedDisplayImage(url: URL, maxPixelSize: CGFloat) -> (image: NSImage, facts: SourceFacts)? {
        DisplayImageCache.shared.cached(url: url, requestedMaxPixel: maxPixelSize)
    }

    static func prefetchDisplay(url: URL, maxPixelSize: CGFloat) {
        DisplayImageCache.shared.prefetch(url: url, maxPixelSize: maxPixelSize)
    }

    // MARK: ImageIO

    static func makeSource(_ url: URL) -> CGImageSource? {
        let options: [CFString: Any] = [kCGImageSourceShouldCache: false]
        return CGImageSourceCreateWithURL(url as CFURL, options as CFDictionary)
    }

    /// 位图顺时针旋转 90°(重排像素,输出宽高对调)。
    /// 显示层旋转用这个而不是 CATransform:旋转后的图与缩放/平移/升级解码共用同一套几何数学,
    /// 无需在任何路径上做「宽高是否对调」的特判。
    static func rotatedCW90(_ cg: CGImage) -> CGImage? {
        let outW = cg.height
        let outH = cg.width
        guard outW > 0, outH > 0 else { return nil }
        let colorSpace = cg.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!
        guard let ctx = CGContext(
            data: nil, width: outW, height: outH,
            bitsPerComponent: cg.bitsPerComponent, bytesPerRow: 0,
            space: colorSpace, bitmapInfo: cg.bitmapInfo.rawValue
        ) else { return nil }
        // 顺时针:源左上角 → 设备右上角。CTM = translate(0, srcW) ∘ rotate(-90°),
        // 绘制矩形必须用「源」尺寸(用输出尺寸会把图压扁)
        ctx.translateBy(x: 0, y: CGFloat(cg.width))
        ctx.rotate(by: -.pi / 2)
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: CGFloat(cg.width), height: CGFloat(cg.height)))
        return ctx.makeImage()
    }

    static func facts(from source: CGImageSource) -> SourceFacts {
        var facts = SourceFacts()
        facts.frameCount = CGImageSourceGetCount(source)
        facts.formatID = CGImageSourceGetType(source) as String?
        if let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] {
            let storedWidth = props[kCGImagePropertyPixelWidth] as? Int ?? 0
            let storedHeight = props[kCGImagePropertyPixelHeight] as? Int ?? 0
            // 解码一律走 WithTransform,位图是摆正后的。
            // 尺寸也按摆正后的语义给出,否则裁切坐标、缩放读数、升级判定都会落在另一套坐标系上。
            let swap = orientationSwapsAxes(orientation(from: props))
            facts.pixelWidth = swap ? storedHeight : storedWidth
            facts.pixelHeight = swap ? storedWidth : storedHeight
        }
        return facts
    }

    static func makeCGImage(source: CGImageSource, maxPixelSize: CGFloat?) -> CGImage? {
        // 全尺寸也走 Thumbnail + Transform,与浏览解码同一套 EXIF 摆正;
        // CreateImageAtIndex 不应用方向,替换时宽高比会对不上,缩放后会挪一下。
        let facts = facts(from: source)
        let maxPixel = maxPixelSize ?? max(facts.maxPixel, 1)
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceShouldCache: false,
        ]
        if let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) {
            return cg
        }
        return CGImageSourceCreateImageAtIndex(
            source, 0,
            [kCGImageSourceShouldCacheImmediately: true, kCGImageSourceShouldCache: false] as CFDictionary
        )
    }
}

/// 浏览分辨率解码缓存:合并同 URL 的进行中请求,全尺寸不入库(避免 40MP+ 撑爆内存)
final class DisplayImageCache: @unchecked Sendable {

    static let shared = DisplayImageCache()

    private let cache = NSCache<NSURL, DisplayImageRecord>()
    private let lock = NSLock()
    private var inFlight: [NSURL: [(DisplayImageRecord?) -> Void]] = [:]

    init() {
        // 6 张 + 250MB 上限，避免 1000 张 40MP 预取撑爆 500MB 红线；NSCache 会在压力下自动逐出
        cache.countLimit = 12
        cache.totalCostLimit = 250 * 1024 * 1024
        cache.evictsObjectsWithDiscardedContent = true
        NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.trimIfNeeded() }
    }

    func trimIfNeeded() {
        // 后台回前台时若内存紧张，NSCache 已自动逐出；此处仅作兜底日志
    }

    func cancelAll() {
        lock.lock()
        let abandoned = inFlight
        inFlight.removeAll()
        lock.unlock()
        // 唤醒等待者:withCheckedContinuation 不响应取消,直接丢弃会让 Task 永久挂起
        for waiters in abandoned.values { for waiter in waiters { waiter(nil) } }
    }

    func clearIfMemoryPressure() {
        cache.removeAllObjects()
        cancelAll()
    }

    func cached(url: URL, requestedMaxPixel: CGFloat) -> (image: NSImage, facts: ImageLoader.SourceFacts)? {
        guard let rec = cache.object(forKey: url as NSURL) else { return nil }
        guard ImageLoader.cachedSatisfies(
            cachedMaxPixel: rec.maxPixelSize,
            truePixelMax: rec.facts.maxPixel,
            requestedMaxPixel: requestedMaxPixel
        ) else { return nil }
        return (rec.image, rec.facts)
    }

    func image(for url: URL, maxPixelSize: CGFloat) async -> (image: NSImage, facts: ImageLoader.SourceFacts)? {
        if let hit = cached(url: url, requestedMaxPixel: maxPixelSize) { return hit }
        let rec: DisplayImageRecord? = await withCheckedContinuation { cont in
            enqueue(url: url, maxPixelSize: maxPixelSize) { rec in
                cont.resume(returning: rec)
            }
        }
        guard let rec else { return nil }
        return (rec.image, rec.facts)
    }

    func prefetch(url: URL, maxPixelSize: CGFloat) {
        if cached(url: url, requestedMaxPixel: maxPixelSize) != nil { return }
        enqueue(url: url, maxPixelSize: maxPixelSize) { _ in }
    }

    private func enqueue(url: URL, maxPixelSize: CGFloat, completion: @escaping (DisplayImageRecord?) -> Void) {
        let key = url as NSURL
        lock.lock()
        if let rec = cache.object(forKey: key),
           ImageLoader.cachedSatisfies(
            cachedMaxPixel: rec.maxPixelSize,
            truePixelMax: rec.facts.maxPixel,
            requestedMaxPixel: maxPixelSize
           ) {
            lock.unlock()
            completion(rec)
            return
        }
        inFlight[key, default: []].append(completion)
        let needsStart = inFlight[key]?.count == 1
        lock.unlock()
        guard needsStart else { return }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let decoded = try? ImageLoader.decodeWithFacts(url: url, maxPixelSize: maxPixelSize)
            let rec: DisplayImageRecord?
            if let decoded {
                let record = DisplayImageRecord(image: decoded.image, facts: decoded.facts, maxPixelSize: maxPixelSize)
                rec = record
                let px = decoded.image.representations.first
                let cost = (px?.pixelsWide ?? 0) * (px?.pixelsHigh ?? 0) * 4
                self.lock.lock()
                if let existing = self.cache.object(forKey: key),
                   let existingMax = existing.maxPixelSize,
                   existingMax + 0.5 >= maxPixelSize {
                    self.lock.unlock()
                } else {
                    self.cache.setObject(record, forKey: key, cost: max(cost, 1))
                    self.lock.unlock()
                }
            } else {
                rec = nil
            }
            self.lock.lock()
            let waiters = self.inFlight.removeValue(forKey: key) ?? []
            self.lock.unlock()
            for waiter in waiters { waiter(rec) }
        }
    }
}

final class DisplayImageRecord: NSObject, @unchecked Sendable {
    let image: NSImage
    let facts: ImageLoader.SourceFacts
    let maxPixelSize: CGFloat?

    init(image: NSImage, facts: ImageLoader.SourceFacts, maxPixelSize: CGFloat?) {
        self.image = image
        self.facts = facts
        self.maxPixelSize = maxPixelSize
    }
}
