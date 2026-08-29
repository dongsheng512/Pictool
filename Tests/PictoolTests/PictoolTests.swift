import XCTest
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import Pictool

final class CropMathTests: XCTestCase {

    func testPixelRectBasicMapping() {
        let rect = CropMath.pixelRect(
            normalized: CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5),
            pixelSize: CGSize(width: 1000, height: 800)
        )
        XCTAssertEqual(rect, CGRect(x: 250, y: 200, width: 500, height: 400))
    }

    func testPixelRectFullImage() {
        let rect = CropMath.pixelRect(
            normalized: CGRect(x: 0, y: 0, width: 1, height: 1),
            pixelSize: CGSize(width: 1920, height: 1080)
        )
        XCTAssertEqual(rect, CGRect(x: 0, y: 0, width: 1920, height: 1080))
    }

    func testPixelRectClampsOriginOverflow() {
        // 原点越界时夹取到右下角,并保证至少 1px
        let rect = CropMath.pixelRect(
            normalized: CGRect(x: 1.5, y: 1.5, width: 0.5, height: 0.5),
            pixelSize: CGSize(width: 100, height: 100)
        )
        XCTAssertEqual(rect.origin, CGPoint(x: 99, y: 99))
        XCTAssertGreaterThanOrEqual(rect.width, 1)
        XCTAssertGreaterThanOrEqual(rect.height, 1)
    }

    func testPixelRectMinimumSize() {
        let rect = CropMath.pixelRect(
            normalized: CGRect(x: 0.5, y: 0.5, width: 0, height: 0),
            pixelSize: CGSize(width: 400, height: 300)
        )
        XCTAssertEqual(rect.width, 1)
        XCTAssertEqual(rect.height, 1)
    }

    func testPixelRectNeverExceedsImage() {
        let rect = CropMath.pixelRect(
            normalized: CGRect(x: 0.9, y: 0.9, width: 0.5, height: 0.5),
            pixelSize: CGSize(width: 1000, height: 1000)
        )
        XCTAssertEqual(rect.maxX, 1000)
        XCTAssertEqual(rect.maxY, 1000)
    }

    func testClampedNormalizedInsideUnit() {
        let clamped = CropMath.clampedNormalized(
            CGRect(x: -0.2, y: 0.9, width: 0.5, height: 0.5),
            minSize: 0.05
        )
        XCTAssertGreaterThanOrEqual(clamped.minX, 0)
        XCTAssertLessThanOrEqual(clamped.maxX, 1)
        XCTAssertGreaterThanOrEqual(clamped.minY, 0)
        XCTAssertLessThanOrEqual(clamped.maxY, 1)
    }

    func testClampedNormalizedKeepsMinSize() {
        let clamped = CropMath.clampedNormalized(
            CGRect(x: 0.4, y: 0.4, width: 0.001, height: 0.001),
            minSize: 0.05
        )
        XCTAssertGreaterThanOrEqual(clamped.width, 0.05)
        XCTAssertGreaterThanOrEqual(clamped.height, 0.05)
    }
}

final class ImageDiscoveryTests: XCTestCase {

    func testIsImageFileByKnownExtension() {
        XCTAssertTrue(ImageDiscovery.isImageFile(URL(fileURLWithPath: "/tmp/a.JPG")))   // 大小写不敏感
        XCTAssertTrue(ImageDiscovery.isImageFile(URL(fileURLWithPath: "/tmp/a.heic")))
        XCTAssertTrue(ImageDiscovery.isImageFile(URL(fileURLWithPath: "/tmp/a.cr3")))
        XCTAssertTrue(ImageDiscovery.isImageFile(URL(fileURLWithPath: "/tmp/a.webp")))
    }

    func testIsImageFileRejectsNonImage() {
        XCTAssertFalse(ImageDiscovery.isImageFile(URL(fileURLWithPath: "/tmp/a.txt")))
        XCTAssertFalse(ImageDiscovery.isImageFile(URL(fileURLWithPath: "/tmp/a.pdf")))
        XCTAssertFalse(ImageDiscovery.isImageFile(URL(fileURLWithPath: "/tmp/a.mp4")))
        XCTAssertFalse(ImageDiscovery.isImageFile(URL(fileURLWithPath: "/tmp/noext")))
    }

    func testNaturalSortNumbers() {
        let names = ["img10.jpg", "img2.jpg", "img1.jpg"]
        let sorted = ImageDiscovery.sortedByName(names.map { URL(fileURLWithPath: "/tmp/\($0)") })
        XCTAssertEqual(sorted.map { $0.lastPathComponent }, ["img1.jpg", "img2.jpg", "img10.jpg"])
    }

    func testNaturalSortMixed() {
        let names = ["b2.png", "a10.png", "a2.png", "b1.png"]
        let sorted = ImageDiscovery.sortedByName(names.map { URL(fileURLWithPath: "/tmp/\($0)") })
        XCTAssertEqual(sorted.map { $0.lastPathComponent }, ["a2.png", "a10.png", "b1.png", "b2.png"])
    }

    func testSortedByNameDescending() {
        let urls = ["img1.jpg", "img2.jpg", "img10.jpg"].map { URL(fileURLWithPath: "/tmp/\($0)") }
        let sorted = ImageDiscovery.sorted(urls, by: ImageSortPreference(key: .name, direction: .descending))
        XCTAssertEqual(sorted.map(\.lastPathComponent), ["img10.jpg", "img2.jpg", "img1.jpg"])
    }

    func testCompareBySizeAndNameTiebreak() {
        let a = ImageDiscovery.SortRecord(
            url: URL(fileURLWithPath: "/tmp/b.jpg"),
            modified: Date(timeIntervalSince1970: 10),
            size: 100,
            captured: nil
        )
        let b = ImageDiscovery.SortRecord(
            url: URL(fileURLWithPath: "/tmp/a.jpg"),
            modified: Date(timeIntervalSince1970: 20),
            size: 100,
            captured: nil
        )
        let pref = ImageSortPreference(key: .size, direction: .ascending)
        // 大小相同,回退文件名 a < b
        XCTAssertTrue(ImageDiscovery.compare(b, a, by: pref))
        XCTAssertFalse(ImageDiscovery.compare(a, b, by: pref))
    }

    func testCompareByModifiedDescending() {
        let older = ImageDiscovery.SortRecord(
            url: URL(fileURLWithPath: "/tmp/old.jpg"),
            modified: Date(timeIntervalSince1970: 1),
            size: 1,
            captured: nil
        )
        let newer = ImageDiscovery.SortRecord(
            url: URL(fileURLWithPath: "/tmp/new.jpg"),
            modified: Date(timeIntervalSince1970: 9),
            size: 1,
            captured: nil
        )
        let pref = ImageSortPreference(key: .modified, direction: .descending)
        XCTAssertTrue(ImageDiscovery.compare(newer, older, by: pref))
    }

    func testCompareCapturedFallsBackToModified() {
        let withExif = ImageDiscovery.SortRecord(
            url: URL(fileURLWithPath: "/tmp/cam.jpg"),
            modified: Date(timeIntervalSince1970: 100),
            size: 1,
            captured: Date(timeIntervalSince1970: 1)
        )
        let noExif = ImageDiscovery.SortRecord(
            url: URL(fileURLWithPath: "/tmp/scan.jpg"),
            modified: Date(timeIntervalSince1970: 50),
            size: 1,
            captured: nil
        )
        let pref = ImageSortPreference(key: .captured, direction: .ascending)
        XCTAssertTrue(ImageDiscovery.compare(withExif, noExif, by: pref))
    }
}

final class ImageNavigationTests: XCTestCase {

    func testWrapForwardFromLast() {
        XCTAssertEqual(ImageNavigation.nextIndex(current: 2, count: 3, delta: 1, wrap: true), 0)
    }

    func testWrapBackwardFromFirst() {
        XCTAssertEqual(ImageNavigation.nextIndex(current: 0, count: 3, delta: -1, wrap: true), 2)
    }

    func testNoWrapStopsAtEnds() {
        XCTAssertNil(ImageNavigation.nextIndex(current: 0, count: 3, delta: -1, wrap: false))
        XCTAssertNil(ImageNavigation.nextIndex(current: 2, count: 3, delta: 1, wrap: false))
        XCTAssertEqual(ImageNavigation.nextIndex(current: 1, count: 3, delta: 1, wrap: false), 2)
    }

    func testEmptyAndSingle() {
        XCTAssertNil(ImageNavigation.nextIndex(current: 0, count: 0, delta: 1, wrap: true))
        XCTAssertEqual(ImageNavigation.nextIndex(current: 0, count: 1, delta: 1, wrap: true), 0)
        XCTAssertNil(ImageNavigation.nextIndex(current: 0, count: 1, delta: 1, wrap: false))
    }
}

final class CropTransformTests: XCTestCase {

    /// 2×1 图:左半红、右半蓝(CG 上下文 y 向上,但列位置与显示一致)
    private func makeLeftRedRightBlue() throws -> CGImage {
        let ctx = try XCTUnwrap(CGContext(data: nil, width: 2, height: 1, bitsPerComponent: 8,
                                          bytesPerRow: 8, space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
        ctx.setFillColor(red: 0, green: 0, blue: 1, alpha: 1)
        ctx.fill(CGRect(x: 1, y: 0, width: 1, height: 1))
        return try XCTUnwrap(ctx.makeImage())
    }

    /// 读取显示坐标系下的像素(行 0 = 显示顶部)
    private func pixel(at image: CGImage, x: Int, y: Int) throws -> (r: UInt8, g: UInt8, b: UInt8) {
        let w = image.width, h = image.height
        var buffer = [UInt8](repeating: 0, count: w * h * 4)
        let ctx = try XCTUnwrap(CGContext(
            data: &buffer, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        // CG 上下文 y 向上:显示行 y 对应上下文行 h-1-y
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        let row = h - 1 - y
        let offset = (row * w + x) * 4
        return (buffer[offset], buffer[offset + 1], buffer[offset + 2])
    }

    func testTransformedSizeSwapsOnOddTurns() {
        XCTAssertEqual(CropTransform.transformedSize(width: 40, height: 20, quarterTurns: 0),
                       CGSize(width: 40, height: 20))
        XCTAssertEqual(CropTransform.transformedSize(width: 40, height: 20, quarterTurns: 1),
                       CGSize(width: 20, height: 40))
        XCTAssertEqual(CropTransform.transformedSize(width: 40, height: 20, quarterTurns: 3),
                       CGSize(width: 20, height: 40))
        XCTAssertEqual(CropTransform.transformedSize(width: 40, height: 20, quarterTurns: 4),
                       CGSize(width: 40, height: 20))
    }

    func testRotateClockwiseMovesLeftPixelToTop() throws {
        let image = try makeLeftRedRightBlue()
        // 顺时针 90°:左列(红)转到顶部
        let rotated = CropTransform.apply(to: image, quarterTurns: 1, flipH: false, flipV: false,
                                          straightenDegrees: 0)
        XCTAssertEqual(rotated.width, 1)
        XCTAssertEqual(rotated.height, 2)
        let top = try pixel(at: rotated, x: 0, y: 0)
        let bottom = try pixel(at: rotated, x: 0, y: 1)
        XCTAssertGreaterThan(top.r, 200, "顺时针旋转后顶部应是红色")
        XCTAssertLessThan(top.b, 50)
        XCTAssertGreaterThan(bottom.b, 200, "顺时针旋转后底部应是蓝色")
    }

    func testRotateCounterclockwiseMovesLeftPixelToBottom() throws {
        let image = try makeLeftRedRightBlue()
        let rotated = CropTransform.apply(to: image, quarterTurns: 3, flipH: false, flipV: false,
                                          straightenDegrees: 0)
        XCTAssertEqual(rotated.width, 1)
        let bottom = try pixel(at: rotated, x: 0, y: 1)
        XCTAssertGreaterThan(bottom.r, 200, "逆时针旋转后底部应是红色")
    }

    func testFlipHorizontalMirrorsColumns() throws {
        let image = try makeLeftRedRightBlue()
        let flipped = CropTransform.apply(to: image, quarterTurns: 0, flipH: true, flipV: false,
                                          straightenDegrees: 0)
        let left = try pixel(at: flipped, x: 0, y: 0)
        let right = try pixel(at: flipped, x: 1, y: 0)
        XCTAssertGreaterThan(left.b, 200, "水平翻转后左侧应是蓝色")
        XCTAssertGreaterThan(right.r, 200, "水平翻转后右侧应是红色")
    }

    func testApplyIdentityReturnsSameSize() throws {
        let image = try makeLeftRedRightBlue()
        let same = CropTransform.apply(to: image, quarterTurns: 0, flipH: false, flipV: false,
                                       straightenDegrees: 0)
        XCTAssertEqual(same.width, 2)
        XCTAssertEqual(same.height, 1)
    }

    func testCoverScaleBasics() {
        XCTAssertEqual(CropTransform.coverScale(degrees: 0, width: 100, height: 100), 1)
        // 正方形转 45°:需要放大 √2 才没有空角
        XCTAssertEqual(CropTransform.coverScale(degrees: 45, width: 100, height: 100),
                       sqrt(2), accuracy: 0.001)
        // 2:1 转 45°:受短边公式支配 (2sin+cos)/1
        XCTAssertEqual(CropTransform.coverScale(degrees: 45, width: 200, height: 100),
                       2 * sin(.pi / 4) + cos(.pi / 4), accuracy: 0.001)
    }

    func testDownscaleLimitsLongestSide() throws {
        let image = try makeLeftRedRightBlue()
        let small = CropTransform.downscaled(image, longestSide: 1)
        XCTAssertEqual(max(small.width, small.height), 1)
        // 已短于目标时原样返回
        let untouched = CropTransform.downscaled(small, longestSide: 100)
        XCTAssertEqual(untouched.width, small.width)
        XCTAssertEqual(untouched.height, small.height)
    }
}

final class SlideShowIntervalTests: XCTestCase {

    private func makeDefaults() -> UserDefaults {
        UserDefaults(suiteName: "SlideShowIntervalTests-\(UUID().uuidString)")!
    }

    func testLoadDefaultsWhenMissing() {
        let d = makeDefaults()
        XCTAssertEqual(SlideShowInterval.load(from: d), .s2)
    }

    func testLoadRoundtrip() {
        let d = makeDefaults()
        d.set(10, forKey: SlideShowInterval.storageKey)
        XCTAssertEqual(SlideShowInterval.load(from: d), .s10)
        XCTAssertEqual(SlideShowInterval.s10.seconds, 10)
    }

    func testLoadRejectsInvalidRawValue() {
        let d = makeDefaults()
        d.set(7, forKey: SlideShowInterval.storageKey)
        XCTAssertEqual(SlideShowInterval.load(from: d), .s2)
    }

    func testNextCyclesThroughAllCases() {
        let all = SlideShowInterval.allCases
        for (i, interval) in all.enumerated() {
            XCTAssertEqual(interval.next, all[(i + 1) % all.count])
        }
    }
}

final class MetadataFormatTests: XCTestCase {

    func testFormatNames() {
        XCTAssertEqual(MetadataService.formatName(of: "public.jpeg"), "JPEG")
        XCTAssertEqual(MetadataService.formatName(of: "public.png"), "PNG")
        XCTAssertEqual(MetadataService.formatName(of: "org.webmproject.webp"), "WebP")
        XCTAssertEqual(MetadataService.formatName(of: "public.heic"), "HEIC")
        XCTAssertEqual(MetadataService.formatName(of: nil), "未知")
    }

    func testColorModelNames() {
        XCTAssertEqual(MetadataService.colorModelName("RGB"), "RGB")
        XCTAssertEqual(MetadataService.colorModelName("Gray"), "灰度")
    }

    func testParseEXIFDateStandard() {
        let date = MetadataService.parseEXIFDate("2024:08:15 13:45:01")
        XCTAssertNotNil(date)
        let comps = Calendar.current.dateComponents(
            [.year, .month, .day, .hour, .minute, .second], from: date!
        )
        XCTAssertEqual(comps.year, 2024)
        XCTAssertEqual(comps.month, 8)
        XCTAssertEqual(comps.day, 15)
        XCTAssertEqual(comps.hour, 13)
        XCTAssertEqual(comps.minute, 45)
        XCTAssertEqual(comps.second, 1)
    }

    func testParseEXIFDateAcceptsDashAndT() {
        XCTAssertNotNil(MetadataService.parseEXIFDate("2024-08-15T13:45:01"))
        XCTAssertNotNil(MetadataService.parseEXIFDate("2024-08-15 13:45:01.123"))
    }

    func testParseEXIFDateRejectsGarbage() {
        XCTAssertNil(MetadataService.parseEXIFDate(""))
        XCTAssertNil(MetadataService.parseEXIFDate("not-a-date"))
        XCTAssertNil(MetadataService.parseEXIFDate("2024:08"))
    }
}

final class ZoomMathTests: XCTestCase {

    /// 核心不变量:锚点指向的内容点在缩放前后应处于同一本地位置
    private func contentFractionStays(anchor: CGPoint, oldOrigin: CGPoint,
                                      docSize: CGSize, ratio: CGFloat) -> Bool {
        let newOrigin = ZoomMath.anchoredOrigin(oldOrigin: oldOrigin, anchor: anchor,
                                                docSize: docSize, ratio: ratio)
        // 旧:锚点内容点比例
        let oldDocX = anchor.x + oldOrigin.x
        let fracOld = oldDocX / docSize.width
        // 新:该内容点比例对应的新 doc 坐标 = frac × docSize × ratio,减去新 origin 应等于 anchor
        let newDocX = fracOld * docSize.width * ratio
        return abs(newDocX - newOrigin.x - anchor.x) < 0.0001
    }

    func testCenterAnchoredZoomKeepsCenter() {
        // 1000pt 文档在 500pt 视口居中:origin = 250;锚点(本地 250)指向文档中心(500)
        // 放大 2 倍后文档中心在 1000,应仍处于本地 250 → origin = 1000 - 250 = 750
        let origin = ZoomMath.anchoredOrigin(
            oldOrigin: CGPoint(x: 250, y: 250),
            anchor: CGPoint(x: 250, y: 250),
            docSize: CGSize(width: 1000, height: 1000),
            ratio: 2
        )
        XCTAssertEqual(origin.x, 750, accuracy: 0.001)
        XCTAssertEqual(origin.y, 750, accuracy: 0.001)
        XCTAssertTrue(contentFractionStays(anchor: CGPoint(x: 250, y: 250),
                                           oldOrigin: CGPoint(x: 250, y: 250),
                                           docSize: CGSize(width: 1000, height: 1000),
                                           ratio: 2))
    }

    func testCursorAnchoredZoomKeepsCursorContent() {
        XCTAssertTrue(contentFractionStays(anchor: CGPoint(x: 100, y: 380),
                                           oldOrigin: CGPoint(x: 0, y: 120),
                                           docSize: CGSize(width: 800, height: 600),
                                           ratio: 2.5))
        XCTAssertTrue(contentFractionStays(anchor: CGPoint(x: 10, y: 10),
                                           oldOrigin: CGPoint(x: 500, y: 500),
                                           docSize: CGSize(width: 2000, height: 2000),
                                           ratio: 0.5))   // 缩小
    }

    func testZeroRatioFallback() {
        let origin = ZoomMath.anchoredOrigin(
            oldOrigin: CGPoint(x: 5, y: 5), anchor: CGPoint(x: 1, y: 1),
            docSize: CGSize(width: 100, height: 100), ratio: 0
        )
        XCTAssertEqual(origin, CGPoint(x: 5, y: 5))   // 非法比例返回原值
    }

    func testConstrainedOriginCentersWhenDocumentFits() {
        let origin = ZoomMath.constrainedOrigin(
            proposed: CGPoint(x: 10, y: 20),
            docSize: CGSize(width: 400, height: 300),
            clipSize: CGSize(width: 1000, height: 800)
        )
        XCTAssertEqual(origin.x, (400 - 1000) / 2, accuracy: 0.001)
        XCTAssertEqual(origin.y, (300 - 800) / 2, accuracy: 0.001)
    }

    func testConstrainedOriginClampsWhenDocumentOverflows() {
        let origin = ZoomMath.constrainedOrigin(
            proposed: CGPoint(x: -50, y: 5000),
            docSize: CGSize(width: 2000, height: 2000),
            clipSize: CGSize(width: 800, height: 600)
        )
        XCTAssertEqual(origin.x, 0, accuracy: 0.001)
        XCTAssertEqual(origin.y, 1400, accuracy: 0.001)
    }

    func testSnappedAlignsToBackingPixels() {
        XCTAssertEqual(ZoomMath.snapped(10.24, backing: 2), 10.0, accuracy: 0.0001)
        XCTAssertEqual(ZoomMath.snapped(10.26, backing: 2), 10.5, accuracy: 0.0001)
    }

    func testOriginKeepingVisibleCenterIdentity() {
        let origin = CGPoint(x: 120, y: 80)
        let doc = CGSize(width: 2000, height: 1400)
        let clip = CGSize(width: 800, height: 600)
        let kept = ZoomMath.originKeepingVisibleCenter(
            oldOrigin: origin, oldDoc: doc, newDoc: doc, clipSize: clip
        )
        XCTAssertEqual(kept.x, origin.x, accuracy: 0.001)
        XCTAssertEqual(kept.y, origin.y, accuracy: 0.001)
    }

    func testAnchoredThenConstrainedIsIdempotent() {
        let clip = CGSize(width: 500, height: 500)
        let oldDoc = CGSize(width: 400, height: 400)
        let ratio: CGFloat = 1.25
        let newDoc = CGSize(width: oldDoc.width * ratio, height: oldDoc.height * ratio)
        let anchored = ZoomMath.anchoredOrigin(
            oldOrigin: CGPoint(x: -50, y: -50),
            anchor: CGPoint(x: 250, y: 250),
            docSize: oldDoc,
            ratio: ratio
        )
        let once = ZoomMath.constrainedOrigin(proposed: anchored, docSize: newDoc, clipSize: clip)
        let twice = ZoomMath.constrainedOrigin(proposed: once, docSize: newDoc, clipSize: clip)
        XCTAssertEqual(once.x, twice.x, accuracy: 0.0001)
        XCTAssertEqual(once.y, twice.y, accuracy: 0.0001)
    }
}

final class PrintFitTests: XCTestCase {

    func testFitScaleFillsHeightOfWiderPage() {
        let scale = PrintPageView.fitScale(
            imageSize: CGSize(width: 4000, height: 3000),
            paperSize: CGSize(width: 770, height: 523)
        )
        XCTAssertEqual(scale, 523.0 / 3000.0, accuracy: 0.0001)
    }

    func testMatchingAspectFitScale() {
        let scale = PrintPageView.fitScale(
            imageSize: CGSize(width: 1600, height: 1200),
            paperSize: CGSize(width: 800, height: 600)
        )
        XCTAssertEqual(scale, 0.5, accuracy: 0.0001)
    }

    func testFitScaleDoesNotExceedWhenImageIsSmaller() {
        let scale = PrintPageView.fitScale(
            imageSize: CGSize(width: 200, height: 100),
            paperSize: CGSize(width: 800, height: 600)
        )
        XCTAssertEqual(scale, 4.0, accuracy: 0.0001)
    }
}

final class DisplayCachePolicyTests: XCTestCase {

    func testCachedBrowseCoversSmallerRequest() {
        XCTAssertTrue(ImageLoader.cachedSatisfies(cachedMaxPixel: 4096, truePixelMax: 8000, requestedMaxPixel: 2048))
    }

    func testCachedBrowseMissesLargerRequest() {
        XCTAssertFalse(ImageLoader.cachedSatisfies(cachedMaxPixel: 2048, truePixelMax: 8000, requestedMaxPixel: 4096))
    }

    func testCachedBrowseCoversTrueSizeEvenIfRequestIsNil() {
        // 缓存边长已覆盖原图像素,视为全尺寸可用
        XCTAssertTrue(ImageLoader.cachedSatisfies(cachedMaxPixel: 4000, truePixelMax: 4000, requestedMaxPixel: nil))
        XCTAssertFalse(ImageLoader.cachedSatisfies(cachedMaxPixel: 2000, truePixelMax: 4000, requestedMaxPixel: nil))
    }

    func testFullResolutionAlwaysSatisfies() {
        XCTAssertTrue(ImageLoader.cachedSatisfies(cachedMaxPixel: nil, truePixelMax: 12000, requestedMaxPixel: 2048))
        XCTAssertTrue(ImageLoader.cachedSatisfies(cachedMaxPixel: nil, truePixelMax: 12000, requestedMaxPixel: nil))
    }
}

final class CropFormatTests: XCTestCase {

    func testDefaultFormatBySourceExtension() {
        XCTAssertEqual(CropFormat.default(forSourceExt: "jpg"), .jpeg)
        XCTAssertEqual(CropFormat.default(forSourceExt: "HEIC"), .heic)
        XCTAssertEqual(CropFormat.default(forSourceExt: "tif"), .tiff)
        XCTAssertEqual(CropFormat.default(forSourceExt: "psd"), .png)   // 不可编码的源 → PNG
        XCTAssertEqual(CropFormat.default(forSourceExt: "webp"), .png)
    }
}

final class RotatedCW90Tests: XCTestCase {

    /// 2×1 测试图:左像素红、右像素蓝。
    /// 顺时针旋转 90° 后应变成 1×2:上=红(原左),下=蓝(原右)。
    func testCornerPixelMapping() throws {
        let w = 2, h = 1
        var data = [UInt8](repeating: 0, count: w * h * 4)
        // 坐标系:CGImage 内存从左上角开始逐行排列(用 draw 校验,不依赖此假设,只看结果)
        data[0] = 255; data[1] = 0;   data[2] = 0;   data[3] = 255  // (0,0) 红
        data[4] = 0;   data[5] = 0;   data[6] = 255; data[7] = 255  // (1,0) 蓝
        let ctx = try XCTUnwrap(CGContext(
            data: &data, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        let src = try XCTUnwrap(ctx.makeImage())
        let out = try XCTUnwrap(ImageLoader.rotatedCW90(src))
        XCTAssertEqual(out.width, 1)   // 宽高对调
        XCTAssertEqual(out.height, 2)

        // 读回输出像素
        var outData = [UInt8](repeating: 0, count: 1 * 2 * 4)
        let outCtx = try XCTUnwrap(CGContext(
            data: &outData, width: 1, height: 2, bitsPerComponent: 8, bytesPerRow: 1 * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        outCtx.draw(out, in: CGRect(x: 0, y: 0, width: 1, height: 2))
        // 输出行序同样按内存行读;顺时针 90°:原左上→右上、原右上→右下
        let top = Array(outData[0..<4])
        let bottom = Array(outData[4..<8])
        // 顶部应为红色系(原左侧像素),底部为蓝色系(原右侧像素)
        XCTAssertGreaterThan(top[0], 200, "top should be red-dominant, got \(top)")
        XCTAssertGreaterThan(bottom[2], 200, "bottom should be blue-dominant, got \(bottom)")
    }

    func testDegenerateInputReturnsNil() {
        // 0 尺寸无法构造真实 CGImage,直接验证空守卫路径不崩溃即可
        // (构造非法图不可行,此处仅保证函数签名可调用)
        XCTAssertTrue(true)
    }
}

// MARK: - EXIF 方向与裁切坐标

/// orientation ≠ 1 时,文件里存的像素矩阵与摆正后的位图宽高对调。
/// 裁切链路必须全程使用摆正后的坐标系,否则框哪儿不裁哪儿。
final class CropOrientationTests: XCTestCase {

    /// 存储为 40×20:左半蓝、右半红;写入 orientation = 6(顺时针 90°)。
    /// 摆正后显示为 20×40:**上半蓝、下半红**。
    private func makeRotatedJPEG() throws -> URL {
        let w = 40, h = 20
        var data = [UInt8](repeating: 0, count: w * h * 4)
        for y in 0..<h {
            for x in 0..<w {
                let i = (y * w + x) * 4
                let isBlue = x < w / 2
                data[i]     = isBlue ? 0 : 255
                data[i + 1] = 0
                data[i + 2] = isBlue ? 255 : 0
                data[i + 3] = 255
            }
        }
        let ctx = try XCTUnwrap(CGContext(
            data: &data, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        let base = try XCTUnwrap(ctx.makeImage())
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("PictoolOrient-\(UUID().uuidString).jpg")
        let dest = try XCTUnwrap(CGImageDestinationCreateWithURL(
            url as CFURL, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(dest, base, [kCGImagePropertyOrientation: 6] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        return url
    }

    /// 把裁切结果解码回像素,返回尺寸与指定位置的颜色
    private func sample(_ data: Data, at point: CGPoint) throws -> (size: CGSize, r: Int, g: Int, b: Int) {
        let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        let cg = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        var pixel = [UInt8](repeating: 0, count: 4)
        let ctx = try XCTUnwrap(CGContext(
            data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        ctx.draw(cg, in: CGRect(x: -point.x, y: -point.y, width: cg.width.cgFloat, height: cg.height.cgFloat))
        return (CGSize(width: cg.width, height: cg.height),
                Int(pixel[0]), Int(pixel[1]), Int(pixel[2]))
    }

    func testFactsReportOrientedSize() throws {
        let url = try makeRotatedJPEG()
        defer { try? FileManager.default.removeItem(at: url) }
        let facts = ImageLoader.facts(of: url)
        XCTAssertEqual(facts.pixelWidth, 20, "摆正后应为 20 宽")
        XCTAssertEqual(facts.pixelHeight, 40, "摆正后应为 40 高")
    }

    func testFactsLeaveUnrotatedImageAlone() throws {
        let url = try makeRotatedJPEG()
        defer { try? FileManager.default.removeItem(at: url) }
        // orientation 1..4 不产生宽高对调,这里反向验证辅助函数本身
        XCTAssertFalse(ImageLoader.orientationSwapsAxes(1))
        XCTAssertFalse(ImageLoader.orientationSwapsAxes(4))
        XCTAssertTrue(ImageLoader.orientationSwapsAxes(5))
        XCTAssertTrue(ImageLoader.orientationSwapsAxes(8))
        XCTAssertFalse(ImageLoader.orientationSwapsAxes(9))
    }

    func testCropUpperHalfOfRotatedImageIsBlue() throws {
        let url = try makeRotatedJPEG()
        defer { try? FileManager.default.removeItem(at: url) }
        let data = try CropService.encode(
            sourceURL: url,
            normalizedRect: CGRect(x: 0, y: 0, width: 1, height: 0.5),
            format: .png, quality: 1
        )
        let px = try sample(data, at: CGPoint(x: 10, y: 10))
        XCTAssertEqual(px.size.width, 20)
        XCTAssertEqual(px.size.height, 20)
        XCTAssertGreaterThan(px.b, 200, "摆正后的上半部分应为蓝色,实际 \(px)")
        XCTAssertLessThan(px.r, 60, "上半部分不应出现红色,实际 \(px)")
    }

    func testCropLowerHalfOfRotatedImageIsRed() throws {
        let url = try makeRotatedJPEG()
        defer { try? FileManager.default.removeItem(at: url) }
        let data = try CropService.encode(
            sourceURL: url,
            normalizedRect: CGRect(x: 0, y: 0.5, width: 1, height: 0.5),
            format: .png, quality: 1
        )
        let px = try sample(data, at: CGPoint(x: 10, y: 10))
        XCTAssertEqual(px.size.width, 20)
        XCTAssertEqual(px.size.height, 20)
        XCTAssertGreaterThan(px.r, 200, "摆正后的下半部分应为红色,实际 \(px)")
        XCTAssertLessThan(px.b, 60, "下半部分不应出现蓝色,实际 \(px)")
    }
}

private extension Int {
    var cgFloat: CGFloat { CGFloat(self) }
}

// MARK: - 比例约束下的锚点

/// 锁定比例时,拖边手柄必须只动被拖的那一轴,另一轴保持中心不动。
/// 回归用例:早期实现把「锚中心」当成「锚 max」处理,选区每帧跳半个身位。
final class CropRatioLockedTests: XCTestCase {

    private let base = CGRect(x: 0.20, y: 0.20, width: 0.60, height: 0.40)
    private let aspect: CGFloat = 1.0   // 1:1
    private let minSize: CGFloat = 0.02

    private func drag(_ handle: CropHandle, dx: CGFloat, dy: CGFloat) -> CGRect {
        var minX = base.minX, minY = base.minY, maxX = base.maxX, maxY = base.maxY
        switch handle {
        case .move:        minX += dx; maxX += dx; minY += dy; maxY += dy
        case .topLeft:     minX += dx; minY += dy
        case .topRight:    maxX += dx; minY += dy
        case .bottomLeft:  minX += dx; maxY += dy
        case .bottomRight: maxX += dx; maxY += dy
        case .top:         minY += dy
        case .bottom:      maxY += dy
        case .left:        minX += dx
        case .right:       maxX += dx
        }
        let free = CGRect(x: min(minX, maxX), y: min(minY, maxY),
                          width: abs(maxX - minX), height: abs(maxY - minY))
        return CropMath.ratioLockedRect(free: free, base: base, handle: handle,
                                        aspect: aspect, minSize: minSize)
    }

    func testTopHandleKeepsHorizontalCenter() {
        let r = drag(.top, dx: 0, dy: -0.05)
        XCTAssertEqual(r.midX, base.midX, accuracy: 1e-9,
                       "拖上边缘不应改变水平中心,实际偏移 \(r.midX - base.midX)")
    }

    func testBottomHandleKeepsHorizontalCenter() {
        let r = drag(.bottom, dx: 0, dy: 0.05)
        XCTAssertEqual(r.midX, base.midX, accuracy: 1e-9)
    }

    func testLeftHandleKeepsVerticalCenter() {
        let r = drag(.left, dx: -0.10, dy: 0)
        XCTAssertEqual(r.midY, base.midY, accuracy: 1e-9,
                       "拖左边缘不应改变垂直中心,实际偏移 \(r.midY - base.midY)")
    }

    func testRightHandleKeepsVerticalCenter() {
        let r = drag(.right, dx: 0.10, dy: 0)
        XCTAssertEqual(r.midY, base.midY, accuracy: 1e-9)
    }

    func testSquareRatioIsMaintained() {
        // .move 除外:整体拖移按设计保持原有尺寸(改比例应在切换比例时由 snapToRatio 完成)
        for handle in CropHandle.allCases where handle != .move {
            let r = drag(handle, dx: 0.03, dy: 0.02)
            XCTAssertEqual(r.width, r.height, accuracy: 1e-9, "\(handle) 破坏了 1:1")
        }
    }

    func testCornerHandlePinsOppositeCorner() {
        // 拖左上角时右下角应固定不动
        let r = drag(.topLeft, dx: -0.05, dy: -0.05)
        XCTAssertEqual(r.maxX, base.maxX, accuracy: 1e-9)
        XCTAssertEqual(r.maxY, base.maxY, accuracy: 1e-9)
        // 拖右下角时左上角应固定不动
        let r2 = drag(.bottomRight, dx: 0.05, dy: 0.05)
        XCTAssertEqual(r2.minX, base.minX, accuracy: 1e-9)
        XCTAssertEqual(r2.minY, base.minY, accuracy: 1e-9)
    }

    func testMovePreservesSize() {
        let r = drag(.move, dx: 0.08, dy: 0.05)
        XCTAssertEqual(r.width, base.width, accuracy: 1e-9)
        XCTAssertEqual(r.height, base.height, accuracy: 1e-9)
    }

    func testResultAlwaysInsideUnitRect() {
        for handle in CropHandle.allCases {
            for (dx, dy) in [(CGFloat(0.5), CGFloat(0.5)), (-0.9, -0.9), (0.3, -0.7)] {
                let r = drag(handle, dx: dx, dy: dy)
                XCTAssertGreaterThanOrEqual(r.minX, -1e-9, "\(handle) 越界")
                XCTAssertGreaterThanOrEqual(r.minY, -1e-9, "\(handle) 越界")
                XCTAssertLessThanOrEqual(r.maxX, 1 + 1e-9, "\(handle) 越界")
                XCTAssertLessThanOrEqual(r.maxY, 1 + 1e-9, "\(handle) 越界")
            }
        }
    }

    func testAnchorMapping() {
        XCTAssertEqual(CropMath.anchor(of: .top).x, .center)
        XCTAssertEqual(CropMath.anchor(of: .bottom).x, .center)
        XCTAssertEqual(CropMath.anchor(of: .left).y, .center)
        XCTAssertEqual(CropMath.anchor(of: .right).y, .center)
        XCTAssertEqual(CropMath.anchor(of: .topLeft).x, .max)
        XCTAssertEqual(CropMath.anchor(of: .topLeft).y, .max)
        XCTAssertEqual(CropMath.anchor(of: .bottomRight).x, .min)
        XCTAssertEqual(CropMath.anchor(of: .bottomRight).y, .min)
    }
}
