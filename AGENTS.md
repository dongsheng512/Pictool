# AGENTS.md

Pictool:macOS 图片查看器(Swift 6 + SwiftUI 混合 AppKit)。**仓库尚无代码,`PLAN.md` 是唯一规格来源**(模块划分、里程碑 M0–M6、技术决策都在里面),动手前先读。选型与竞品的调研依据存档在 `RESEARCH.md`(仅参考,非规格)。以下是其中最易被违反的硬约束。

## 构建 / 测试
- 纯 SPM 构建,**不建 xcodeproj**(`xcode-select` 当前指向 CommandLineTools);需要 IDE 时用 Xcode 直接打开 `Package.swift`。
- 开发迭代:`swift build`;打包发布:`./build.sh`(release 构建 + 组装 Pictool.app + ad-hoc 签名,M0 验收标准即此脚本产出可启动的 app)。
- 单测:`swift test`,单个用 `swift test --filter <TestName>`。只测纯逻辑(裁切坐标换算、自然排序、格式识别),不测 UI。

## 技术约束(勿"优化"掉)
- 部署目标 macOS 14.0+,Swift 6;**核心零第三方依赖**,SVG / JXL 高画质 / WebP 编码等均为可选二期,不要引包。
- 主视图缩放平移画布必须用 `NSViewRepresentable` 包 `NSScrollView + NSImageView`,不是纯 SwiftUI 手势——刻意的体验决策。
- 文件选择/保存用 `NSOpenPanel`/`NSSavePanel`,打印走 `NSPrintOperation`(SwiftUI 在 macOS 无对应 API)。
- 不做沙盒(本地工具定位);文件夹变更一期手动刷新,不做实时监听。

## 领域要点
- 缩略图:`CGImageSourceCreateThumbnailAtIndex` + `NSCache` + 后台串行队列;主图按屏幕尺寸×2 降采样浏览,**仅缩放超阈值或裁切/导出时才解码全尺寸**。性能红线:1000 张照片文件夹内存 < 500MB。
- 格式能力来自 ImageIO 原生(实测 61 种可解码);**WebP/AVIF 只能解码不能编码**,导出仅 PNG/JPEG/HEIC/TIFF,并尽量保 EXIF(`CGImageDestinationCopyImageSource`)。
- 裁切的屏幕↔像素坐标换算必须抽成纯函数并配单测(全项目唯一强制单测点)。

## 许可证红线
FlowVision、iMonet、nomacs、qView、Art-Book 均为 GPL-3.0,**禁止参考或复制其代码**;可参考 MIT 项目:imageviewer5、Binder、oculante(Rust,仅借鉴思路)。
