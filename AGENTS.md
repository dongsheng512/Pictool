# AGENTS.md

Pictool(PureView):macOS 图片查看器(Swift 6 + SwiftUI 混合 AppKit)。主要功能已实现(浏览/信息/裁切/打印/偏好设置),`PLAN.md` 是总体规格来源(模块划分、里程碑 M0–M6、技术决策都在里面),动手前先读。**文字标记/水印/画笔/马赛克**的唯一执行规格是 `MARKUP_PLAN.md`(期号 A1–A4,不要和 PLAN.md 的 M1–M6 混用);实现 agent 先读该文件第 0 节再写代码。**编辑器交互升级(B0 打磨 / B1 画布缩放 / B2 形状工具 / B3 顶栏收敛 / B4 文字角柄+荧光笔)**的唯一执行规格是 `EDIT_UX_PLAN.md`(期号 B0–B4,**已全部落地**:B0 v0.5.26–0.5.36、B1 0.6.0、B2 0.6.1、B3 0.6.2、B4 0.6.3,as-built 偏差见其文档头)。选型与竞品的调研依据存档在 `RESEARCH.md`(仅参考,非规格)。以下是其中最易被违反的硬约束。

## 构建 / 测试
- 纯 SPM 构建,**不建 xcodeproj**(`xcode-select` 当前指向 CommandLineTools);需要 IDE 时用 Xcode 直接打开 `Package.swift`。
- 开发迭代:`swift build`;打包发布:`./build.sh`(release 构建 + 组装 PureView.app + ad-hoc 签名)。
- 单测:`swift test`,单个用 `swift test --filter <TestName>`。只测纯逻辑(裁切坐标换算、自然排序、格式识别),不测 UI。
- **版本号同步**:唯一来源是 `build.sh` 内嵌 Info.plist 模板的 `CFBundleShortVersionString`;功能性变更合入时同步升版本号,并在 `README.md`「版本」小节追加一行变更摘要。

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
