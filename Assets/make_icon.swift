// 从方形单图生成 macOS 风格 app 图标(圆角主体 + 透明留白)。
// 用法: swift Assets/make_icon.swift <source.jpg/png> <iconset目录>
// 尺寸比例来自 Apple Big Sur 图标模板:1024 画布 / 824 主体 / 圆角 185.4。
import AppKit

guard CommandLine.arguments.count == 3 else {
    FileHandle.standardError.write(Data("usage: make_icon.swift <source> <iconset-dir>\n".utf8))
    exit(1)
}
let srcPath = CommandLine.arguments[1]
let outDir = CommandLine.arguments[2]

guard let img = NSImage(contentsOfFile: srcPath),
      let tiff = img.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let cgSrc = rep.cgImage else {
    FileHandle.standardError.write(Data("无法读取源图: \(srcPath)\n".utf8))
    exit(1)
}

// (画布边长, iconset 文件名)
let specs: [(Int, String)] = [
    (16, "icon_16x16.png"), (32, "icon_16x16@2x.png"),
    (32, "icon_32x32.png"), (64, "icon_32x32@2x.png"),
    (128, "icon_128x128.png"), (256, "icon_128x128@2x.png"),
    (256, "icon_256x256.png"), (512, "icon_256x256@2x.png"),
    (512, "icon_512x512.png"), (1024, "icon_512x512@2x.png"),
]

for (size, name) in specs {
    let s = CGFloat(size)
    guard let ctx = CGContext(
        data: nil, width: size, height: size,
        bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { exit(2) }

    let bodySize = s * 824.0 / 1024.0
    let origin = (s - bodySize) / 2
    let radius = bodySize * 185.4 / 824.0
    let rect = CGRect(x: origin, y: origin, width: bodySize, height: bodySize)

    ctx.clear(rect.insetBy(dx: -origin, dy: -origin))
    ctx.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
    ctx.clip()
    ctx.draw(cgSrc, in: rect)

    guard let masked = ctx.makeImage() else { exit(2) }
    let out = NSBitmapImageRep(cgImage: masked)
    out.size = NSSize(width: s, height: s)
    guard let data = out.representation(using: .png, properties: [:]) else { exit(2) }
    try data.write(to: URL(fileURLWithPath: outDir + "/" + name))
}
print("已生成 \(specs.count) 档图标到 \(outDir)")
