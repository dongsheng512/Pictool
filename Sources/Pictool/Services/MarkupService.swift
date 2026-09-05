import AppKit
import ImageIO
import UniformTypeIdentifiers

/// 标记烙印导出:解码全尺寸 → 带入主视图四分旋转 → 画原图与标记 → 水印
/// → 编码保 EXIF / IPTC,GPS 可关。
enum MarkupService {

    static func encode(sourceURL: URL,
                       annotations: [Annotation],
                       format: CropFormat,
                       quality: Double,
                       quarterTurns: Int = 0,
                       includeGPS: Bool = true,
                       watermark: WatermarkSettings? = nil) throws -> Data {
        let full = try ImageLoader.decodeFullCGImage(url: sourceURL)
        let image = CropTransform.apply(
            to: full, quarterTurns: quarterTurns, flipH: false, flipV: false, straightenDegrees: 0
        )
        let size = CGSize(width: image.width, height: image.height)

        guard let ctx = CGContext(
            data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
            space: image.colorSpace ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { throw CropError.encodeFailed }
        ctx.draw(image, in: CGRect(origin: .zero, size: size))
        AnnotationRenderer.draw(annotations, in: ctx, canvasSize: size, base: image)
        if let watermark, watermark.enabled, watermark.hasContent {
            WatermarkRenderer.draw(watermark, in: ctx, canvasSize: size)
        }
        guard let output = ctx.makeImage() else { throw CropError.encodeFailed }

        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(
            data, format.uti as CFString, 1, nil
        ) else { throw CropError.encodeFailed }

        var properties: [CFString: Any] = [:]
        properties[kCGImagePropertyOrientation] = 1
        if format.isLossy {
            properties[kCGImageDestinationLossyCompressionQuality] = quality
        }
        if let source = CGImageSourceCreateWithURL(sourceURL as CFURL, nil),
           let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] {
            for key in [kCGImagePropertyExifDictionary, kCGImagePropertyIPTCDictionary] {
                if let value = props[key] { properties[key] = value }
            }
            if includeGPS, let gps = props[kCGImagePropertyGPSDictionary] {
                properties[kCGImagePropertyGPSDictionary] = gps
            }
        }
        CGImageDestinationAddImage(dest, output, properties as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw CropError.encodeFailed }
        return data as Data
    }
}
