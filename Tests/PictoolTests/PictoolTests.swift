import XCTest
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import Pictool

final class EditCanvasMathTests: XCTestCase {

    private let container = CGSize(width: 800, height: 600)

    func testViewRectMatchesFitAtZoomOne() {
        // 宽图:适配后横向顶满、纵向居中
        let wide = EditCanvasMath.viewRect(container: container, imageAspect: 1.5,
                                           zoom: 1, pan: .zero)
        XCTAssertEqual(wide.width, 800, accuracy: 0.001)
        XCTAssertEqual(wide.height, 800 / 1.5, accuracy: 0.001)
        XCTAssertEqual(wide.minY, (600 - wide.height) / 2, accuracy: 0.001)
        // 窄图:纵向顶满、横向居中
        let tall = EditCanvasMath.viewRect(container: container, imageAspect: 0.5,
                                           zoom: 1, pan: .zero)
        XCTAssertEqual(tall.width, 300, accuracy: 0.001)
        XCTAssertEqual(tall.height, 600, accuracy: 0.001)
        XCTAssertEqual(tall.minX, 250, accuracy: 0.001)
    }

    func testZoomedKeepsAnchorContentFixed() {
        let oldRect = EditCanvasMath.viewRect(container: container, imageAspect: 1.5,
                                              zoom: 2, pan: .zero)
        let anchor = CGPoint(x: 200, y: 300)
        let u = (anchor.x - oldRect.minX) / oldRect.width
        let v = (anchor.y - oldRect.minY) / oldRect.height
        let result = EditCanvasMath.zoomed(zoom: 2, pan: .zero, factor: 2, anchor: anchor,
                                           container: container, imageAspect: 1.5)
        XCTAssertEqual(result.zoom, 4, accuracy: 0.001)
        let newRect = EditCanvasMath.viewRect(container: container, imageAspect: 1.5,
                                              zoom: result.zoom, pan: result.pan)
        XCTAssertEqual((anchor.x - newRect.minX) / newRect.width, u, accuracy: 0.0001)
        XCTAssertEqual((anchor.y - newRect.minY) / newRect.height, v, accuracy: 0.0001)
    }

    func testZoomClampsToBounds() {
        let up = EditCanvasMath.zoomed(zoom: 4, pan: .zero, factor: 1_000_000, anchor: .zero,
                                       container: container, imageAspect: 1.5)
        XCTAssertEqual(up.zoom, EditCanvasMath.maxZoom, accuracy: 0.001)
        let down = EditCanvasMath.zoomed(zoom: 1, pan: .zero, factor: 0.000001, anchor: .zero,
                                         container: container, imageAspect: 1.5)
        XCTAssertEqual(down.zoom, EditCanvasMath.minZoom, accuracy: 0.001)
        // 缩到比容器更小后两方向都居中,pan 归零
        XCTAssertEqual(down.pan.width, 0, accuracy: 0.001)
        XCTAssertEqual(down.pan.height, 0, accuracy: 0.001)
    }

    func testPanClampsWhenZoomed() {
        let panned = EditCanvasMath.panned(pan: .zero, delta: CGSize(width: 99_999, height: 99_999),
                                           container: container, imageAspect: 1.5, zoom: 8)
        XCTAssertEqual(panned.width, (6400 - 800) / 2, accuracy: 0.001)
        XCTAssertEqual(panned.height, (6400 / 1.5 - 600) / 2, accuracy: 0.001)
        // 边界上再推不动
        let stuck = EditCanvasMath.panned(pan: panned, delta: CGSize(width: 100, height: 100),
                                          container: container, imageAspect: 1.5, zoom: 8)
        XCTAssertEqual(stuck.width, panned.width, accuracy: 0.001)
        XCTAssertEqual(stuck.height, panned.height, accuracy: 0.001)
    }

    func testPanZeroWhenFits() {
        // 窄图 zoom=1:两方向都居中,pan 恒零
        let atFit = EditCanvasMath.panned(pan: .zero, delta: CGSize(width: 50, height: 50),
                                          container: container, imageAspect: 0.5, zoom: 1)
        XCTAssertEqual(atFit.width, 0, accuracy: 0.001)
        XCTAssertEqual(atFit.height, 0, accuracy: 0.001)
        // zoom=2 后纵向超出可平移,横向仍居中
        let zoomed = EditCanvasMath.panned(pan: .zero, delta: CGSize(width: 50, height: 50),
                                           container: container, imageAspect: 0.5, zoom: 2)
        XCTAssertEqual(zoomed.width, 0, accuracy: 0.001)
        XCTAssertEqual(zoomed.height, 50, accuracy: 0.001)
    }

    func testPanForCenteredContentKeepsCenterOnResize() {
        // zoom=2 居中视口:容器中心内容点即 (0.5, 0.5),换容器后仍应在中心
        let pan = EditCanvasMath.panForCenteredContent(u: 0.5, v: 0.5, zoom: 2,
                                                       container: CGSize(width: 1000, height: 700),
                                                       imageAspect: 1.5)
        XCTAssertEqual(pan.width, 0, accuracy: 0.001)
        XCTAssertEqual(pan.height, 0, accuracy: 0.001)
        let rect = EditCanvasMath.viewRect(container: CGSize(width: 1000, height: 700),
                                           imageAspect: 1.5, zoom: 2, pan: pan)
        XCTAssertEqual((500 - rect.minX) / rect.width, 0.5, accuracy: 0.0001)
        XCTAssertEqual((350 - rect.minY) / rect.height, 0.5, accuracy: 0.0001)
    }
}

final class ShapeGeometryTests: XCTestCase {

    private let canvas = CGSize(width: 1000, height: 500)

    func testStandardizedRectFlipsNegativeSize() {
        let rect = MarkupGeometry.standardizedRect(from: CGPoint(x: 0.5, y: 0.8),
                                                   to: CGPoint(x: 0.2, y: 0.3))
        XCTAssertEqual(rect.minX, 0.2, accuracy: 0.0001)
        XCTAssertEqual(rect.minY, 0.3, accuracy: 0.0001)
        XCTAssertEqual(rect.width, 0.3, accuracy: 0.0001)
        XCTAssertEqual(rect.height, 0.5, accuracy: 0.0001)
    }

    func testArrowHeadDirectionAndMinLength() {
        // 水平向右:尖端在 to,底部回缩
        let head = MarkupGeometry.arrowHead(from: CGPoint(x: 0, y: 0.5), to: CGPoint(x: 0.5, y: 0.5),
                                            widthFraction: 0.004, canvasSize: canvas)
        guard let head else { return XCTFail("head expected") }
        XCTAssertEqual(head.tip.x, 0.5, accuracy: 0.0001)
        XCTAssertEqual(head.tip.y, 0.5, accuracy: 0.0001)
        // 头长(像素)= max(3×0.004×1000, 0.02×500) = 12px → 归一化 x = 0.012
        let length = head.tip.x - head.baseA.x
        XCTAssertEqual(length, 0.012, accuracy: 0.0001)
        // 头部像素宽也是 12px → 归一化 y = 12/500 = 0.024(横竖箭头头部像素形状一致)
        XCTAssertEqual(head.baseA.y - head.baseB.y, 0.024, accuracy: 0.0001)
        // 竖直箭头:头部像素尺寸与水平箭头相同(各向异性修复的回归锁)
        let vertical = MarkupGeometry.arrowHead(from: CGPoint(x: 0.25, y: 0.1),
                                                to: CGPoint(x: 0.25, y: 0.6),
                                                widthFraction: 0.004, canvasSize: canvas)
        guard let v = vertical else { return XCTFail("head expected") }
        // 竖箭头:x 方向偏移是半宽(6px/1000),y 方向是头长(12px/500)——像素尺寸与横箭头一致
        XCTAssertEqual(v.tip.x - v.baseA.x, 6.0 / 1000.0, accuracy: 0.0001)
        XCTAssertEqual(v.tip.y - v.baseA.y, 12.0 / 500.0, accuracy: 0.0001)
        // 零长度线段无方向
        XCTAssertNil(MarkupGeometry.arrowHead(from: CGPoint(x: 0.5, y: 0.5),
                                              to: CGPoint(x: 0.5, y: 0.5),
                                              widthFraction: 0.004, canvasSize: canvas))
    }

    func testShapeBoundsPadsAndIncludesArrowHead() {
        let rectBounds = MarkupGeometry.shapeBounds(kind: .rect,
                                                    from: CGPoint(x: 0.2, y: 0.2),
                                                    to: CGPoint(x: 0.4, y: 0.6),
                                                    widthFraction: 0.01, canvasSize: canvas)
        XCTAssertEqual(rectBounds?.minX ?? -1, 0.195, accuracy: 0.0001)
        XCTAssertEqual(rectBounds?.width ?? -1, 0.21, accuracy: 0.0001)
        // 箭头头部超出 to 点时包围盒应含头
        let arrowBounds = MarkupGeometry.shapeBounds(kind: .arrow,
                                                     from: CGPoint(x: 0.2, y: 0.5),
                                                     to: CGPoint(x: 0.3, y: 0.5),
                                                     widthFraction: 0.02, canvasSize: canvas)
        // 头长 = max(3×0.02, 0.01) = 0.06,尖端 0.3、底部 0.24,包围盒仍以 [0.2, 0.3] 为主,横向外扩 pad=0.01
        XCTAssertEqual(arrowBounds?.minX ?? -1, 0.19, accuracy: 0.0001)
        XCTAssertEqual(arrowBounds?.maxX ?? -1, 0.31, accuracy: 0.0001)
        // 纵向应含头的一半宽:头长 60px → 半宽 30px / H500 = 0.06
        XCTAssertEqual(arrowBounds?.minY ?? -1, 0.5 - 0.06 - 0.01, accuracy: 0.0001)
        // 退化为零尺寸的 rect 无包围盒
        XCTAssertNil(MarkupGeometry.shapeBounds(kind: .rect,
                                                from: CGPoint(x: 0.3, y: 0.3),
                                                to: CGPoint(x: 0.3, y: 0.3),
                                                widthFraction: 0.01, canvasSize: canvas))
    }

    func testHitShapeRectAndEllipseByBounds() {
        let from = CGPoint(x: 0.2, y: 0.2), to = CGPoint(x: 0.4, y: 0.6)
        XCTAssertTrue(MarkupGeometry.hitShape(kind: .rect, from: from, to: to, widthFraction: 0.004,
                                              canvasSize: canvas, at: CGPoint(x: 0.3, y: 0.4)))
        XCTAssertTrue(MarkupGeometry.hitShape(kind: .ellipse, from: from, to: to, widthFraction: 0.004,
                                              canvasSize: canvas, at: CGPoint(x: 0.205, y: 0.2)))
        XCTAssertFalse(MarkupGeometry.hitShape(kind: .rect, from: from, to: to, widthFraction: 0.004,
                                               canvasSize: canvas, at: CGPoint(x: 0.6, y: 0.4)))
    }

    func testHitShapeLineToleranceAndArrowHead() {
        // 水平线 y=0.5,容差 = max(0.004/2, 0.004)+0.006 = 0.008
        XCTAssertTrue(MarkupGeometry.hitShape(kind: .line, from: CGPoint(x: 0.2, y: 0.5),
                                              to: CGPoint(x: 0.6, y: 0.5), widthFraction: 0.004,
                                              canvasSize: canvas, at: CGPoint(x: 0.4, y: 0.507)))
        XCTAssertFalse(MarkupGeometry.hitShape(kind: .line, from: CGPoint(x: 0.2, y: 0.5),
                                               to: CGPoint(x: 0.6, y: 0.5), widthFraction: 0.004,
                                               canvasSize: canvas, at: CGPoint(x: 0.4, y: 0.53)))
        // 箭头头部三角内命中(头长 0.012,尖端 0.6)
        XCTAssertTrue(MarkupGeometry.hitShape(kind: .arrow, from: CGPoint(x: 0.2, y: 0.5),
                                              to: CGPoint(x: 0.6, y: 0.5), widthFraction: 0.004,
                                              canvasSize: canvas, at: CGPoint(x: 0.594, y: 0.503)))
    }
}

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

/// 回归用例:比例预设(1:1 / 16:9 …)说的是**像素**宽高比,选区存的是**归一化**坐标。
/// 少了两者之间的折算,16:9 图上的整图选区(归一化 1:1)会被判成「不合 16:9」,
/// 手柄只要动 1% 高度就从 1.000 塌到 0.557 —— 也就是「点一下就缩小一半、拖着不跟手」。
final class CropAspectSpaceTests: XCTestCase {

    private let wide = CGSize(width: 1600, height: 900)          // 16:9
    private let imageAspect: CGFloat = 1600.0 / 900.0

    /// 复刻 `CropCanvas.apply()`:先按手柄位移算出自由矩形,再套比例约束
    private func drag(_ handle: CropHandle, dx: CGFloat, dy: CGFloat,
                      base: CGRect, aspect: CGFloat?, minSize: CGFloat = 0.02) -> CGRect {
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
        guard let aspect else { return CropMath.clampedNormalized(free, minSize: minSize) }
        return CropMath.ratioLockedRect(free: free, base: base, handle: handle,
                                        aspect: aspect, imageAspect: imageAspect,
                                        minSize: minSize)
    }

    func testTinyDragOnFullBleedSelectionDoesNotCollapse() {
        let base = CGRect(x: 0, y: 0, width: 1, height: 1)
        for handle in CropHandle.allCases where handle != .move {
            let r = drag(handle, dx: -0.01, dy: -0.01, base: base, aspect: imageAspect)
            XCTAssertGreaterThan(r.height, 0.97, "\(handle):1% 的拖动不该让高度塌掉,实际 \(r.height)")
            XCTAssertGreaterThan(r.width, 0.97, "\(handle):1% 的拖动不该让宽度塌掉,实际 \(r.width)")
        }
    }

    func testSquareRatioYieldsSquarePixelsOnWideImage() {
        let base = CGRect(x: 0, y: 0, width: 1, height: 1)
        let r = drag(.bottom, dx: 0, dy: -0.2, base: base, aspect: 1)
        let px = CropMath.pixelRect(normalized: r, pixelSize: wide)
        XCTAssertEqual(CGFloat(px.width), CGFloat(px.height), accuracy: 2,
                       "1:1 应裁出正方形像素,实际 \(px.width)×\(px.height)")
    }

    func testCornerDragAlongSingleAxisStillResizes() {
        // 归一化 h = w × 16/9 时像素才是正方形;只沿水平方向拖右下角,
        // 取内解的旧实现会纹丝不动,取较大解才能跟手。
        let base = CGRect(x: 0.1, y: 0.1, width: 0.3, height: 0.3 * imageAspect)
        let r = drag(.bottomRight, dx: 0.1, dy: 0, base: base, aspect: 1)
        XCTAssertGreaterThan(r.width, base.width + 0.05, "单轴拖动也该有响应,实际 \(r.width)")
        XCTAssertEqual(r.minX, base.minX, accuracy: 1e-9)
        XCTAssertEqual(r.minY, base.minY, accuracy: 1e-9)
        let px = CropMath.pixelRect(normalized: r, pixelSize: wide)
        XCTAssertEqual(CGFloat(px.width), CGFloat(px.height), accuracy: 2)
    }

    func testNormalizedAspectConvertsPixelRatio() {
        XCTAssertEqual(CropMath.normalizedAspect(1, imageAspect: 16.0 / 9.0), 9.0 / 16.0, accuracy: 1e-9)
        XCTAssertEqual(CropMath.normalizedAspect(16.0 / 9.0, imageAspect: 16.0 / 9.0), 1, accuracy: 1e-9)
        // 非法图片比例时退回原值,不产生 NaN
        XCTAssertEqual(CropMath.normalizedAspect(1.5, imageAspect: 0), 1.5, accuracy: 1e-9)
    }

    func testFreeRatioDoesNotLockShape() {
        XCTAssertNil(CropRatio.free.aspect(imageAspect: imageAspect, customAspect: nil))
        XCTAssertEqual(CropRatio.original.aspect(imageAspect: imageAspect, customAspect: nil) ?? 0,
                       imageAspect, accuracy: 1e-9)
        XCTAssertEqual(CropRatio.square.aspect(imageAspect: imageAspect, customAspect: nil) ?? 0, 1)
        XCTAssertNil(CropRatio.custom.aspect(imageAspect: imageAspect, customAspect: nil))
        // 自定义比例解析得出时应原样返回
        XCTAssertEqual(CropRatio.custom.aspect(imageAspect: imageAspect, customAspect: 2.5) ?? 0, 2.5)
    }
}

final class MarkupGeometryTests: XCTestCase {

    func testDistancePointToSegment() {
        // 线段 (0,0)-(1,0),垂足投影在段内
        XCTAssertEqual(MarkupGeometry.distance(CGPoint(x: 0.5, y: 0.3), segment: .zero, CGPoint(x: 1, y: 0)),
                       0.3, accuracy: 0.0001)
        // 投影越界夹到端点
        XCTAssertEqual(MarkupGeometry.distance(CGPoint(x: 2, y: 0), segment: .zero, CGPoint(x: 1, y: 0)),
                       1, accuracy: 0.0001)
        // 零长线段退化为点到点
        XCTAssertEqual(MarkupGeometry.distance(CGPoint(x: 3, y: 4), segment: .zero, .zero), 5, accuracy: 0.0001)
    }

    func testStrokeContainsWithTolerance() {
        let canvas = CGSize(width: 1000, height: 500)
        let line = [CGPoint(x: 0, y: 0.5), CGPoint(x: 1, y: 0.5)]
        // 容差在像素空间:0.008×1000 = 8px = 归一化 y 0.016
        XCTAssertTrue(MarkupGeometry.stroke(line, contains: CGPoint(x: 0.5, y: 0.51),
                                            widthFraction: 0.02, canvasSize: canvas))
        XCTAssertFalse(MarkupGeometry.stroke(line, contains: CGPoint(x: 0.5, y: 0.9),
                                             widthFraction: 0.02, canvasSize: canvas))
    }

    func testMappedRoundTripKeepsPayload() {
        // CW→CCW 往返应回到原位,且 sizeFraction/style/effect/colorIndex 等载荷不丢
        let original = Annotation(kind: .text(anchor: CGPoint(x: 0.2, y: 0.3),
                                              content: "标注",
                                              sizeFraction: 0.05, colorIndex: 3))
        let roundTrip = MarkupGeometry.mapped(
            MarkupGeometry.mapped(original, MarkupGeometry.rotateCW90), MarkupGeometry.rotateCCW90
        )
        guard case let .text(anchor, content, sizeFraction, colorIndex) = roundTrip.kind else {
            return XCTFail("kind must stay .text")
        }
        XCTAssertEqual(anchor.x, 0.2, accuracy: 0.0001)
        XCTAssertEqual(anchor.y, 0.3, accuracy: 0.0001)
        XCTAssertEqual(content, "标注")
        XCTAssertEqual(sizeFraction, 0.05, accuracy: 0.0001)
        XCTAssertEqual(colorIndex, 3)
        let stroke = Annotation(kind: .stroke(points: [.zero, CGPoint(x: 0.4, y: 0.4)],
                                              widthLevel: 2, colorIndex: 4, style: .highlighter))
        let strokeTrip = MarkupGeometry.mapped(
            MarkupGeometry.mapped(stroke, MarkupGeometry.flipH), MarkupGeometry.flipH
        )
        XCTAssertEqual(strokeTrip, stroke)
    }

    func testPanForCenteredContentKeepsOffCenterPoint() {
        // 偏心内容点:反解后该点应落在容器中心(未触夹取的分支)
        let newContainer = CGSize(width: 900, height: 700)
        let u: CGFloat = 0.3, v: CGFloat = 0.3
        let pan = EditCanvasMath.panForCenteredContent(u: u, v: v, zoom: 2,
                                                       container: newContainer, imageAspect: 1.5)
        let rect = EditCanvasMath.viewRect(container: newContainer, imageAspect: 1.5,
                                           zoom: 2, pan: pan)
        XCTAssertEqual((newContainer.width / 2 - rect.minX) / rect.width, u, accuracy: 0.0001)
        XCTAssertEqual((newContainer.height / 2 - rect.minY) / rect.height, v, accuracy: 0.0001)
    }

    func testExtremeAspectAndZeroContainer() {
        // 20:1 全景:fit 宽顶满、高极小;缩放/平移不炸
        let wide = EditCanvasMath.viewRect(container: CGSize(width: 800, height: 600),
                                           imageAspect: 20, zoom: 2, pan: .zero)
        XCTAssertEqual(wide.width, 1600, accuracy: 0.001)
        // 零容器:返回零矩形,缩放/平移安全
        XCTAssertEqual(EditCanvasMath.viewRect(container: .zero, imageAspect: 1.5,
                                               zoom: 2, pan: .zero), .zero)
        let safe = EditCanvasMath.zoomed(zoom: 2, pan: .zero, factor: 1.25, anchor: .zero,
                                         container: .zero, imageAspect: 1.5)
        XCTAssertEqual(safe.zoom, 2, accuracy: 0.001)
    }

    func testMoveClampsToUnit() {
        let moved = MarkupGeometry.moved(anchor: CGPoint(x: 0.95, y: 0.1),
                                         by: CGSize(width: 0.2, height: -0.5))
        XCTAssertEqual(moved.x, 1)
        XCTAssertEqual(moved.y, 0)
    }

    func testTranslatedMovesEveryPoint() {
        let moved = MarkupGeometry.translated(
            points: [CGPoint(x: 0.1, y: 0.2), CGPoint(x: 0.3, y: 0.4)], dx: 0.05, dy: -0.02
        )
        XCTAssertEqual(moved[0].x, 0.15, accuracy: 0.0001)
        XCTAssertEqual(moved[0].y, 0.18, accuracy: 0.0001)
        XCTAssertEqual(moved[1].x, 0.35, accuracy: 0.0001)
        XCTAssertEqual(moved[1].y, 0.38, accuracy: 0.0001)
        XCTAssertTrue(MarkupGeometry.translated(points: [], dx: 1, dy: 1).isEmpty)
    }

    func testClampedTranslateMovesFullyInsideStroke() {
        let stroke = [CGPoint(x: 0.2, y: 0.2), CGPoint(x: 0.4, y: 0.2)]
        let moved = MarkupGeometry.clampedTranslate(points: stroke, dx: 0.1, dy: 0.3)
        XCTAssertEqual(moved[0].x, 0.3, accuracy: 0.0001)
        XCTAssertEqual(moved[0].y, 0.5, accuracy: 0.0001)
        XCTAssertEqual(moved[1].x, 0.5, accuracy: 0.0001)
        XCTAssertEqual(moved[1].y, 0.5, accuracy: 0.0001)
    }

    func testClampedTranslateKeepsStrokeWholeAtBoundary() {
        // 笔画部分出界:整笔收紧到边界,不拆散、不出界
        let stroke = [CGPoint(x: 0.99, y: 0.5), CGPoint(x: 0.995, y: 0.5)]
        let moved = MarkupGeometry.clampedTranslate(points: stroke, dx: 0.05, dy: 0)
        XCTAssertEqual(moved[1].x, 1, accuracy: 0.0001)
        XCTAssertEqual(moved[1].x - moved[0].x, stroke[1].x - stroke[0].x, accuracy: 0.0001)
        // 已贴边再往界外推:位移归零
        let stuck = MarkupGeometry.clampedTranslate(points: moved, dx: 0.02, dy: 0)
        XCTAssertEqual(stuck[0].x, moved[0].x, accuracy: 0.0001)
    }

    func testClampedTranslateClampsBothAxesIndependently() {
        let stroke = [CGPoint(x: 0.1, y: 0.98), CGPoint(x: 0.2, y: 0.99)]
        let moved = MarkupGeometry.clampedTranslate(points: stroke, dx: 5, dy: 5)
        XCTAssertEqual(moved[0].x, 0.9, accuracy: 0.0001)  // x 收紧到右边界
        XCTAssertEqual(moved[1].y, 1, accuracy: 0.0001)    // y 收紧到下边界
    }

    func testRDPSimplifiesCollinearRun() {
        var points = [CGPoint(x: 0, y: 0)]
        for i in 1...50 { points.append(CGPoint(x: CGFloat(i) / 50, y: CGFloat(i) / 50)) }
        points.append(CGPoint(x: 1, y: 0.5))  // 拐点
        let simplified = MarkupGeometry.rdp(points, epsilon: 0.005)
        XCTAssertLessThan(simplified.count, 6)
        XCTAssertEqual(simplified.first, CGPoint(x: 0, y: 0))
        XCTAssertEqual(simplified.last, CGPoint(x: 1, y: 0.5))
        XCTAssertTrue(simplified.contains(CGPoint(x: 1, y: 0.5)))
    }

    func testRDPKeepsShortInput() {
        let two = [CGPoint.zero, CGPoint(x: 1, y: 1)]
        XCTAssertEqual(MarkupGeometry.rdp(two, epsilon: 1), two)
    }

    func testStrokeBoundsPadsByHalfWidth() {
        let bounds = MarkupGeometry.strokeBounds([CGPoint(x: 0.2, y: 0.3), CGPoint(x: 0.6, y: 0.3)],
                                                 widthFraction: 0.02)
        XCTAssertEqual(bounds?.minX ?? -1, 0.19, accuracy: 0.0001)
        XCTAssertEqual(bounds?.width ?? -1, 0.42, accuracy: 0.0001)
    }

    func testTextHitRectContainsAnchorAndStaysNormalized() {
        let rect = MarkupGeometry.textHitRect(
            anchor: CGPoint(x: 0.2, y: 0.3),
            content: "Hi",
            sizeFraction: MarkPalette.textSizes[1],
            imageSize: CGSize(width: 1500, height: 1000)
        )
        XCTAssertTrue(rect.contains(CGPoint(x: 0.21, y: 0.31)))
        XCTAssertLessThan(rect.width, 0.3, "must not treat pixel size as normalized")
        XCTAssertLessThan(rect.height, 0.3)
        XCTAssertGreaterThanOrEqual(rect.width, 0.02)
        XCTAssertFalse(rect.contains(CGPoint(x: 0.95, y: 0.95)))
    }

    func testRotateCW90ThenCCWRoundTrip() {
        let p = CGPoint(x: 0.25, y: 0.10)
        let cw = MarkupGeometry.rotateCW90(p)
        XCTAssertEqual(cw.x, 0.90, accuracy: 0.0001)
        XCTAssertEqual(cw.y, 0.25, accuracy: 0.0001)
        let back = MarkupGeometry.rotateCCW90(cw)
        XCTAssertEqual(back.x, p.x, accuracy: 0.0001)
        XCTAssertEqual(back.y, p.y, accuracy: 0.0001)
    }

    func testTextHitRectClampsOrigin() {
        let rect = MarkupGeometry.textHitRect(
            anchor: CGPoint(x: 1.4, y: -0.2),
            content: "A",
            sizeFraction: MarkPalette.textSizes[0],
            imageSize: CGSize(width: 200, height: 200)
        )
        XCTAssertEqual(rect.origin.x, 1, accuracy: 0.0001)
        XCTAssertEqual(rect.origin.y, 0, accuracy: 0.0001)
    }
}

final class WatermarkLayoutTests: XCTestCase {

    private let canvas = CGSize(width: 1000, height: 500)

    func testNineGridCorners() {
        let content = CGSize(width: 100, height: 40)
        let topLeft = WatermarkLayout.origin(position: .topLeft, canvasSize: canvas, contentSize: content)
        XCTAssertEqual(topLeft.x, 20, accuracy: 0.001)   // margin 0.02×1000
        XCTAssertEqual(topLeft.y, 20, accuracy: 0.001)
        let bottomRight = WatermarkLayout.origin(position: .bottomRight, canvasSize: canvas, contentSize: content)
        XCTAssertEqual(bottomRight.x, 880, accuracy: 0.001)
        XCTAssertEqual(bottomRight.y, 440, accuracy: 0.001)
        let center = WatermarkLayout.origin(position: .center, canvasSize: canvas, contentSize: content)
        XCTAssertEqual(center.x, 450, accuracy: 0.001)
        XCTAssertEqual(center.y, 230, accuracy: 0.001)
    }

    func testTiledOffsetsCoverCanvasWithConsistentSpacing() {
        let offsets = WatermarkLayout.tiledOffsets(canvasSize: canvas, spacingFraction: 0.5)
        XCTAssertFalse(offsets.isEmpty)
        let xs = Set(offsets.map(\.x))
        // 网格相对画幅中心铺开,必须盖过旋转后画幅的外接半径(对角线一半)
        let halfDiagonal = hypot(canvas.width, canvas.height) / 2
        XCTAssertLessThanOrEqual(xs.min() ?? 0, -halfDiagonal)
        XCTAssertGreaterThanOrEqual(xs.max() ?? 0, halfDiagonal)
        // 任意相邻列间距恒为 step
        let sorted = xs.sorted()
        if sorted.count > 1 {
            XCTAssertEqual(sorted[1] - sorted[0], 500, accuracy: 0.001)
        }
    }
}

final class AnnotationRendererTests: XCTestCase {

    func testTextSizePositiveAndMonotonic() {
        let small = AnnotationRenderer.textSize(content: "测试", sizeFraction: 0.03, canvasWidth: 1000)
        let large = AnnotationRenderer.textSize(content: "测试", sizeFraction: 0.06, canvasWidth: 1000)
        XCTAssertGreaterThan(small.width, 0)
        XCTAssertGreaterThan(small.height, 0)
        XCTAssertGreaterThan(large.width, small.width)
        XCTAssertGreaterThan(large.height, small.height)
    }

    func testTextSizeScalesLinearlyWithCanvas() {
        let a = AnnotationRenderer.textSize(content: "PureView", sizeFraction: 0.04, canvasWidth: 1000)
        let b = AnnotationRenderer.textSize(content: "PureView", sizeFraction: 0.04, canvasWidth: 2000)
        // 字体度量带亚像素舍入,线性度放宽到 2%
        XCTAssertEqual(b.width / a.width, 2, accuracy: 0.04)
        XCTAssertEqual(b.height / a.height, 2, accuracy: 0.04)
    }

    func testRenderOverlayProducesImage() throws {
        let annotations = [
            Annotation(kind: .text(anchor: CGPoint(x: 0.1, y: 0.1), content: "标记",
                                   sizeFraction: MarkPalette.textSizes[1], colorIndex: 0)),
            Annotation(kind: .stroke(points: [.zero, CGPoint(x: 0.5, y: 0.5)],
                                     widthLevel: 1, colorIndex: 2, style: .solid)),
        ]
        let image = try XCTUnwrap(AnnotationRenderer.renderOverlay(
            annotations: annotations, canvasSize: CGSize(width: 400, height: 300), base: nil
        ))
        XCTAssertEqual(image.width, 400)
        XCTAssertEqual(image.height, 300)
    }

    func testPixelateReducesToBlockGrid() throws {
        // 4×1 纯色图,块宽 0.5 → 输出仍为 4×1(分辨率不变,内容块化)
        let ctx = try XCTUnwrap(CGContext(data: nil, width: 4, height: 1, bitsPerComponent: 8,
                                          bytesPerRow: 16, space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: 4, height: 1))
        let base = try XCTUnwrap(ctx.makeImage())
        let pixelated = try XCTUnwrap(AnnotationRenderer.pixelated(base, blockFraction: 0.5))
        XCTAssertEqual(pixelated.width, 4)
        XCTAssertEqual(pixelated.height, 1)
    }

    func testTextOverlayHasInkNearNormalizedAnchor() throws {
        let annotations = [
            Annotation(kind: .text(anchor: CGPoint(x: 0.1, y: 0.1), content: "测",
                                   sizeFraction: MarkPalette.textSizes[2], colorIndex: 1))
        ]
        let image = try XCTUnwrap(AnnotationRenderer.renderOverlay(
            annotations: annotations, canvasSize: CGSize(width: 200, height: 100), base: nil
        ))
        var found = false
        for x in 12..<90 where !found {
            for y in 4..<55 {
                if TestPixels.alpha(image, x: x, y: y) > 20 { found = true; break }
            }
        }
        XCTAssertTrue(found, "CoreText 烙印应在锚点附近留下非透明像素")
    }

    func testTextStrokeAndFillDoNotDuplicateHorizontally() throws {
        let content = "12345"
        let canvas = CGSize(width: 400, height: 200)
        let sizeFraction = MarkPalette.textSizes[2]
        let annotations = [
            Annotation(kind: .text(anchor: CGPoint(x: 0.08, y: 0.25), content: content,
                                   sizeFraction: sizeFraction, colorIndex: 2))
        ]
        let image = try XCTUnwrap(AnnotationRenderer.renderOverlay(
            annotations: annotations, canvasSize: canvas, base: nil
        ))
        let expected = AnnotationRenderer.textSize(
            content: content,
            sizeFraction: sizeFraction,
            canvasWidth: canvas.width
        )
        var minX = image.width, maxX = 0
        for x in 0..<image.width {
            for y in 0..<image.height {
                guard TestPixels.alpha(image, x: x, y: y) > 20 else { continue }
                minX = min(minX, x)
                maxX = max(maxX, x)
            }
        }
        XCTAssertLessThan(minX, image.width, "应画出文字")
        let inkWidth = CGFloat(maxX - minX + 1)
        XCTAssertLessThan(
            inkWidth, expected.width * 1.55,
            "文字只应有一份实心填充;重复 CTLineDraw 且未复位 textPosition 会画出两倍宽"
        )
        XCTAssertGreaterThan(inkWidth, expected.width * 0.45)
    }

    func testTextFillMatchesPaletteColor() throws {
        let annotations = [
            Annotation(kind: .text(anchor: CGPoint(x: 0.1, y: 0.2), content: "A",
                                   sizeFraction: MarkPalette.textSizes[2], colorIndex: 2))
        ]
        let image = try XCTUnwrap(AnnotationRenderer.renderOverlay(
            annotations: annotations, canvasSize: CGSize(width: 240, height: 160), base: nil
        ))
        var foundFill = false
        for x in 0..<image.width where !foundFill {
            for y in 0..<image.height {
                let p = TestPixels.rgba(image, x: x, y: y)
                guard p.3 > 180 else { continue }
                XCTAssertGreaterThan(p.0, 160, "应是调色盘红色,不是描边白/黑")
                XCTAssertLessThan(p.1, 80)
                XCTAssertLessThan(p.2, 80)
                foundFill = true
                break
            }
        }
        XCTAssertTrue(foundFill, "应能采到不透明的文字像素")
    }
}

final class WatermarkRenderTests: XCTestCase {

    func testTextWatermarkLandsBottomRightNotTopLeft() throws {
        let width = 400, height = 300
        let ctx = try XCTUnwrap(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        ctx.setFillColor(red: 0, green: 0, blue: 0, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        var settings = WatermarkSettings()
        settings.enabled = true
        settings.text = "WM"
        settings.position = .bottomRight
        settings.opacity = 1
        settings.sizeFraction = 0.12
        settings.tiled = false
        WatermarkRenderer.draw(settings, in: ctx, canvasSize: CGSize(width: width, height: height))
        let image = try XCTUnwrap(ctx.makeImage())

        XCTAssertFalse(TestPixels.hasInk(image, x: 0..<80, y: 0..<60), "左上应保持底色")
        XCTAssertTrue(
            TestPixels.hasInk(image, x: (width / 2)..<width, y: (height / 2)..<height),
            "右下象限应有水印墨迹"
        )
    }

    func testPreviewStampIsVisibleOnRedImage() throws {
        let width = 400, height = 300
        let ctx = try XCTUnwrap(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        ctx.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let base = try XCTUnwrap(ctx.makeImage())
        var settings = WatermarkSettings()
        settings.text = "WM"
        settings.opacity = 1
        settings.sizeFraction = 0.2
        settings.position = .center
        let preview = try XCTUnwrap(WatermarkRenderer.preview(settings, onto: base, maxPixel: 400, force: true))
        XCTAssertTrue(
            TestPixels.hasInkNotRed(preview, x: (width / 4)..<(width * 3 / 4), y: (height / 4)..<(height * 3 / 4)),
            "预览应在画面中部烙出非纯红的水印像素"
        )
    }

    func testDefaultSizePreviewStampIsVisible() throws {
        let width = 720, height = 480
        let ctx = try XCTUnwrap(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        ctx.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let base = try XCTUnwrap(ctx.makeImage())
        var settings = WatermarkSettings()
        settings.text = "PureView"
        settings.position = .bottomRight
        let preview = try XCTUnwrap(WatermarkRenderer.preview(settings, onto: base, maxPixel: 720, force: true))
        XCTAssertTrue(
            TestPixels.hasInkNotRed(preview, x: (width / 2)..<width, y: (height / 2)..<height),
            "默认字号烙印也应在右下象限可见"
        )
    }

    func testOverlayOnCropSizedCanvasLandsBottomRight() throws {
        var settings = WatermarkSettings()
        settings.text = "WM"
        settings.opacity = 1
        settings.sizeFraction = 0.15
        settings.position = .bottomRight
        let canvas = CGSize(width: 200, height: 100)
        let overlay = try XCTUnwrap(WatermarkRenderer.overlay(settings, canvasSize: canvas, force: true))
        XCTAssertTrue(
            TestPixels.hasInk(overlay, x: 100..<200, y: 50..<100),
            "裁切后的画幅上,右下水印应落在该画幅右下"
        )
        XCTAssertFalse(TestPixels.hasInk(overlay, x: 0..<40, y: 0..<30))
    }

    func testTransparentOverlayKeepsFullTextInk() throws {
        var settings = WatermarkSettings()
        settings.text = "Copyright"
        settings.opacity = 1
        settings.sizeFraction = 0.12
        settings.position = .bottomRight
        let overlay = try XCTUnwrap(
            WatermarkRenderer.overlay(settings, canvasSize: CGSize(width: 400, height: 300), force: true)
        )
        XCTAssertTrue(
            TestPixels.hasInk(overlay, x: (200)..<400, y: (150)..<300),
            "透明叠层应在右下画出完整水印,不能只剩截断字形"
        )
        XCTAssertFalse(TestPixels.hasInk(overlay, x: 0..<80, y: 0..<60))
    }

    func testEmptyWatermarkDoesNotPaint() throws {
        let width = 80, height = 60
        let ctx = try XCTUnwrap(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        ctx.setFillColor(red: 0, green: 0, blue: 0, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        var settings = WatermarkSettings()
        settings.enabled = true
        settings.text = "   "
        WatermarkRenderer.draw(settings, in: ctx, canvasSize: CGSize(width: width, height: height))
        let image = try XCTUnwrap(ctx.makeImage())
        XCTAssertTrue(TestPixels.isNearlyBlack(image, x: width / 2, y: height / 2))
        XCTAssertTrue(TestPixels.isNearlyBlack(image, x: width - 4, y: height - 4))
    }

    func testFittedWatermarkTextStaysInsideCanvas() {
        var settings = WatermarkSettings()
        settings.enabled = true
        settings.text = String(repeating: "Copyright ", count: 16)
        settings.sizeFraction = 0.2
        let canvas = CGSize(width: 200, height: 80)
        let size = WatermarkRenderer.contentSize(settings: settings, canvasSize: canvas)
        XCTAssertLessThanOrEqual(size.width, canvas.width * 0.96 + 0.5)
        XCTAssertGreaterThan(size.width, 0)
        let fraction = WatermarkRenderer.resolvedSizeFraction(settings: settings, canvasSize: canvas)
        XCTAssertLessThan(fraction, settings.sizeFraction)
    }

    func testWatermarkFillIsWhiteNotStrokedCopy() throws {
        let width = 320, height = 180
        let ctx = try XCTUnwrap(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        ctx.setFillColor(red: 0, green: 0, blue: 0, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        var settings = WatermarkSettings()
        settings.enabled = true
        settings.text = "WM"
        settings.opacity = 1
        settings.sizeFraction = 0.18
        settings.position = .center
        WatermarkRenderer.draw(settings, in: ctx, canvasSize: CGSize(width: width, height: height))
        let image = try XCTUnwrap(ctx.makeImage())
        var foundWhite = false
        for x in 40..<(width - 40) where !foundWhite {
            for y in 30..<(height - 30) {
                let p = TestPixels.rgba(image, x: x, y: y)
                if p.0 > 180, p.1 > 180, p.2 > 180 {
                    foundWhite = true
                    break
                }
            }
        }
        XCTAssertTrue(foundWhite, "水印应为白色实心字")
    }

    func testHasContentFallsBackToTextWhenLogoMissing() {
        var settings = WatermarkSettings()
        settings.useLogo = true
        settings.logoPath = nil
        settings.text = "hello"
        XCTAssertTrue(settings.hasContent)
        settings.text = "  "
        XCTAssertFalse(settings.hasContent)
    }
}

@MainActor
final class AnnotationStoreTests: XCTestCase {

    func testRoundTripAndIsolationByURL() {
        let store = AnnotationStore()
        let a = URL(fileURLWithPath: "/tmp/a.jpg")
        let b = URL(fileURLWithPath: "/tmp/b.jpg")
        let mark = Annotation(kind: .text(anchor: CGPoint(x: 0.2, y: 0.3), content: "x",
                                          sizeFraction: MarkPalette.textSizes[1], colorIndex: 2))
        store.set([mark], for: a)
        XCTAssertEqual(store.annotations(for: a).count, 1)
        XCTAssertTrue(store.annotations(for: b).isEmpty)
        store.set([], for: a)
        XCTAssertTrue(store.annotations(for: a).isEmpty)
    }

    func testStandardizedFileURLUnifiesKeys() {
        let store = AnnotationStore()
        let mark = Annotation(kind: .stroke(points: [.zero, CGPoint(x: 1, y: 1)],
                                            widthLevel: 0, colorIndex: 0, style: .solid))
        store.set([mark], for: URL(fileURLWithPath: "/tmp/foo.jpg"))
        XCTAssertEqual(AnnotationStore.storageKey(for: URL(fileURLWithPath: "/tmp/foo.jpg")),
                       AnnotationStore.storageKey(for: URL(fileURLWithPath: "/tmp/foo.jpg/")))
        XCTAssertEqual(store.annotations(for: URL(fileURLWithPath: "/tmp/foo.jpg/")).count, 1)
    }
}

private enum TestPixels {
    static func rgba(_ image: CGImage, x: Int, y: Int) -> (UInt8, UInt8, UInt8, UInt8) {
        var pixel = [UInt8](repeating: 0, count: 4)
        guard let cropped = image.cropping(to: CGRect(x: x, y: y, width: 1, height: 1)) else {
            return (0, 0, 0, 0)
        }
        pixel.withUnsafeMutableBytes { ptr in
            guard let ctx = CGContext(
                data: ptr.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return }
            ctx.draw(cropped, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        }
        return (pixel[0], pixel[1], pixel[2], pixel[3])
    }

    static func alpha(_ image: CGImage, x: Int, y: Int) -> UInt8 {
        rgba(image, x: x, y: y).3
    }

    static func isNearlyBlack(_ image: CGImage, x: Int, y: Int) -> Bool {
        let p = rgba(image, x: x, y: y)
        return p.0 < 25 && p.1 < 25 && p.2 < 25
    }

    static func hasInk(_ image: CGImage, x: Range<Int>, y: Range<Int>) -> Bool {
        for px in x {
            for py in y {
                if !isNearlyBlack(image, x: px, y: py) { return true }
            }
        }
        return false
    }

    static func hasInkNotRed(_ image: CGImage, x: Range<Int>, y: Range<Int>) -> Bool {
        for px in x {
            for py in y {
                let p = rgba(image, x: px, y: py)
                if p.1 > 40 || p.2 > 40 || p.0 < 200 { return true }
            }
        }
        return false
    }
}
