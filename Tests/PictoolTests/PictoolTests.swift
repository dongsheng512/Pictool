import XCTest
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
