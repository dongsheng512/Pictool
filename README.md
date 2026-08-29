# PureView v0.2.0

macOS 原生图片查看器 · Swift 6 + SwiftUI(混合 AppKit) · 零第三方依赖 · 支持 61 种格式

> `PureView` 是 Pictool 的应用显示名（Bundle 仍为 `Pictool`），主打 **ApolloOne 式文件夹快翻 + 完整 EXIF + 顺手裁切 + 正经打印** 的 Mac 原生体验。

![macOS 14+](https://img.shields.io/badge/macOS-14%2B-blue) ![Swift 6](https://img.shields.io/badge/Swift-6-orange) ![License MIT](https://img.shields.io/badge/license-MIT-green)

## ✨ v0.1.0 亮点

- **磨砂侧栏 + 纯净顶栏**：侧栏与顶栏左侧共享 `NSVisualEffectView(.sidebar)` 磨砂，右侧与主区柔白 `#FAFAFB` 同色系，无黑线/无透明缝
- **可拖中线**：侧栏右缘 `1px 0.07` 细线 + `16pt 居中热区`，`↔` 光标，`180–400pt` 实时拖动并持久到 `UserDefaults`
- **原生红绿灯**：自绘 `12px` 圆点，悬停整组同显 `× − ⤢`（对角双箭头），激活彩色/失焦灰
- **顶栏重排**：移除刷新，`添加文件夹` 移至右侧按钮组最左，`详情` 移至 `打印` 右侧
- **柔和配色**：画布 `light` 改柔和米白，欢迎页与状态栏同 `headerView` 磨砂，浅色下不刺眼
- **稳定性**：缩略图/主图缓存精确计费 + `utility` 队列 + 切盘 `cancelAll`，1000 张 <500MB 设计落地

## 功能

- **文件夹浏览**：`NSOpenPanel` 多根项目侧栏 + 文件夹树懒加载 + `UTType.image` + `localizedStandardCompare` 自然排序
- **缩略图网格**：边栏下半区 `LazyVGrid` 自适应，`CGImageSourceCreateThumbnailAtIndex` 降采样 + `NSCache(900/80MB)` + 合并重复请求，当前项高亮并自动滚动跟随
- **流畅缩放**：`NSScrollView+NSImageView` 层托管 `CALayer(contents)`，触控板捏合 / `⌘/⌥+滚轮` 锚点缩放 / 拖拽平移 / 双击 `适配↔100%` / 横向主导滑动切图；大图按视口 `×2` 降采样，超阈值自动加载全尺寸无缝替换
- **图片信息**：`CGImageSourceCopyPropertiesAtIndex` 一站式 EXIF/TIFF/IPTC/GPS/色彩/位深/DPI/帧数 + 文件信息，`Inspector` 可折叠 + 一键复制
- **简单裁切**：8 手柄选区 + `自由/1:1/4:3/3:4/16:9/9:16` + 三分线 + 实时像素读数；`CGImage.cropping(to:)` 纯函数换算（单测覆盖），导出 `PNG/JPEG/HEIC/TIFF` 并尽量保留 EXIF
- **打印**：`NSPrintOperation` + `per-job PrintInfo(copy)` + `clip` 分页 + 零边距 + `fitScale` 自动横竖
- **格式广度**：ImageIO 原生 61 种可解码（HEIC/HEIF/AVIF/WebP/JXL/PSD/RAW 全系 CR2/NEF/ARW/RAF/RW2/ORF/DNG…）· 21 种可编码，`WebP/AVIF 只解不编` 已约束
- **交互**：`←→` 切图/`0 适配`/`1 实际`/`⌘=/⌘-` 缩放/`I 信息`/`C 裁切`/`F 纯净`/`⌘R 刷新`/`⌃⌘S 侧栏`，支持文件/文件夹拖入、外部用图定位

## 快捷键

| 按键 | 功能 |
|---|---|
| `⌘O` | 打开文件夹 |
| `← / →` | 上一张 / 下一张（首尾循环） |
| `0` / `1` | 适配窗口 / 实际大小 |
| `⌘=` / `⌘-` | 放大 / 缩小（光标为锚点） |
| `I` | 信息面板 |
| `F` / `Esc` | 只看图（沉浸）/ 退出 |
| `C` | 裁切 |
| `⌘P` | 打印 |
| `⌃⌘S` / `拖中线` | 显/隐侧栏 / 拖动调节 `180–400` |
| `⌘R` | 刷新当前文件夹 |

## 构建与运行

```bash
./build.sh            # release 构建 + 组装 PureView.app（ad-hoc 签名）
open build/PureView.app

swift build           # debug 构建
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test   # 单元测试 31 passed
```

> `XCTest` 不随 CommandLineTools 提供，需 `DEVELOPER_DIR` 指向完整 Xcode。要求 **macOS 14+ / Xcode 16+**。

## 结构

```
Sources/Pictool/
├── PictoolApp.swift              # @main + WindowGroup(hiddenTitleBar) + 菜单
├── Models/
│   ├── CanvasBackground.swift    # 画布背景偏好（UserDefaults）
│   ├── ImageFile.swift           # UTType 识别与自然排序
│   ├── FolderStore.swift         # 多根/选区/隐藏/LRU/预取（@Observable, MainActor）
│   └── ThumbnailProvider.swift   # 缩略图 NSCache + 合并请求 + 精确计费
├── Views/
│   ├── MainContentView.swift     # 三栏布局 + 可拖中线 + 纯净层
│   ├── PureHeader.swift          # 32pt 自绘顶栏 + 分段磨砂 + 红绿灯
│   ├── ImageViewCanvas.swift     # NSScrollView+NSImageView 画布 + 动图
│   ├── SidebarView.swift         # 文件夹树 + 磨砂材质
│   ├── ThumbnailGridView.swift   # 自适应网格 + 虚线空态
│   ├── CropView.swift            # 裁切画布
│   ├── InfoInspector.swift       # 信息面板
│   └── SettingsView.swift        # 设置
└── Services/
    ├── ImageLoader.swift         # 降采样/全尺寸解码 + DisplayImageCache(250MB)
    ├── CropService.swift         # 纯函数坐标换算 + 编码保留 EXIF
    ├── MetadataService.swift     # 格式化
    ├── ZoomMath.swift            # 锚点缩放/像素对齐（单测）
    ├── PrintService.swift        # 打印
    └── L10n.swift
Tests/PictoolTests/               # CropMath / ZoomMath / PrintFit / DisplayCache 等 31 例
```

## 版本

- **v0.2.0** (2026-08-29) — 信息面板改挤压式扁平分区(布局冻结,画布不挤压);深色画布下侧栏深色磨砂 + 顶栏/侧栏亮色适配;缩放修复:捏合以视口中心为锚、锚点夹取坐标系混用导致的深缩放画面偏移、全尺寸换图延迟到动画结束(消除跳变与卡顿)、缩放读数语义统一;修复旋转角度跨纯净模式丢失、外部打开主线程扫盘、打印解码限纸张分辨率、删除确认与隐藏恢复等(UI_REVIEW.md 全部 P0/P1 清零)
- **v0.1.0** (2026-08-24) — 首个可发布预览(当时误标为 v0.10):磨砂侧栏/纯净顶栏/可拖中线/原生红绿灯/柔和配色/稳定性优化
- 更早见 `git log`

## 许可证

MIT · 零第三方依赖（SVG/JXL 等矢量/高画质为可选二期）

> GPL-3.0 项目 `FlowVision/iMonet/nomacs/qView/Art-Book` 禁止参考；可参考 MIT `imageviewer5/Binder/oculante`
