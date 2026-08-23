# Pictool 调研报告

> 记录日期:2026-08-22 · 本文档是选型决策的**依据存档**,规格以 `PLAN.md` 为准
> 调研范围:技术栈对比、Rust+GPUI 专项、Xcode 环境兼容性、竞品分析

---

## 一、技术栈选型(结论:Swift 6 + SwiftUI 混合 AppKit)

### 需求 → 系统 API 映射

| 需求 | 系统 API |
|---|---|
| 文件夹浏览 / 切换 | `FileManager` + 缩略图网格 |
| 缩略图生成 | `CGImageSourceCreateThumbnailAtIndex`(快速、低内存) |
| 图片信息(EXIF 等) | `CGImageSourceCopyPropertiesAtIndex` 一站式元数据 |
| 裁切 | `CGImage.cropping(to:)` / CoreImage |
| 打印 | `NSPrintOperation`,原生打印对话框直接接入 |

格式支持由 **ImageIO 原生提供**(本机实测 61 种可解码,含 HEIC/AVIF/JXL/WebP/全系 RAW)。

### 候选方案对比

| 方案 | 结论 | 关键原因 |
|---|---|---|
| **Swift + SwiftUI/AppKit** | ✅ 采用 | 五项需求全部有系统级 API;体积小、触控板手势/打印体验原生 |
| Electron | ✗ | 内存大、格式靠 sharp/libvips、打印差、包体 150MB+ |
| Tauri + Rust | ✗ | 打印需自行封装原生调用,裁切缩放全要造轮子 |
| Qt / PySide | ✗ | Mac 上不够原生,打印与触控板体验一般 |

---

## 二、Rust + GPU / GPUI 专项调研(评估后放弃,存档备查)

### 技术栈构成(假设走此路线)

`gpui`(macOS 上 Metal 原生渲染)+ `walkdir` + `image-rs` + `objc2-imageio`(补 HEIC)+ `kamadak-exif` + `fast_image_resize`/`rayon` + `objc2-app-kit`(打印桥接)

### 五需求对照

- 文件夹浏览+缩略图:✅ `img` 元素异步纹理加载,但缩略图解码全要自建
- 图片信息:⚠️ kamadak-exif 成熟,信息面板 UI 手写
- 裁切:⚠️ 框选手柄交互纯手工实现
- 格式:⚠️ 最大短板——`image` crate 不支持 HEIC,需 C 桥接;RAW 靠 rawler,覆盖不如 ImageIO
- 打印:❌ 无任何打印概念,必须 objc2 手写 NSPrintOperation FFI

### 优势与风险(2026 年状态)

**优势**:macOS 是 GPUI 一等公民(Metal 直渲,120fps 级平移缩放);经 Zed 生产验证;单二进制、内存占用比 WebView 方案低 60–80%;Tailwind 式声明式 API;社区有 longbridge/gpui-component 控件库。

**风险**(截至 2026-08):
1. pre-1.0,v0.2 才上 crates.io(2025.10),破坏性变更是常态
2. **Zed 团队 2026 年公开放缓 GPUI 独立发展**(优先自身业务,HN 有原话)
3. 文档匮乏,学习方式基本靠读 Zed 源码
4. 打印 + HEIC 都要写 Objective-C 桥接

### 结论

技术上可行且渲染上限更高,但开发成本约为 Swift 方案的 **2–3 倍**,且需求清单中的打印和格式恰踩短板。若坚持 Rust,务实路线是"Rust 核心库 + Swift 外壳"。本项目不采用。

### Rust GUI 生态横向参考(2026)

- 生产就绪度:Tauri ≈ egui > Iced(0.14)> Slint > Dioxus > GPUI > Xilem(alpha)
- 纯 Rust 原生渲染阵营:egui / Iced / Slint / GPUI;WebView 阵营:Tauri / Dioxus
- Iced 0.14 默认响应式渲染,CPU 占用降 60–80%,但 IME 与读屏器仍有缺陷

---

## 三、开发环境:Xcode 版本兼容性(本机 M4 · macOS 15.7.7 Sequoia)

| Xcode | 最低 macOS | 本机可用 |
|---|---|---|
| 16.4 | 15.3+ | ✓ |
| **26.0 – 26.3** | **15.6+** | **✓ 推荐 26.3** |
| 26.4 – 26.6 | 26.2+ | ✗ |
| 27 beta | 26.4+,仅 Apple Silicon | ✗ |

- App Store 门槛:**2026-04-28 起,上架必须用 Xcode 26+(iOS/macOS 26 SDK)构建**
- Deployment Target 可低至 macOS 11,不影响老系统用户运行
- App Store 商店版只会给最新版 → 必须从 developer.apple.com/download/all/(免费 Apple ID 即可)下载 `.xip`
- 安装要点:磁盘预留 ≥40GB;装完 `sudo xcode-select -s`;**不要让 App Store 自动更新 Xcode**

---

## 四、竞品分析(对照五需求)

### 需求覆盖矩阵

| 软件 | 价格 | 浏览+缩略图 | 图片信息 | 裁切 | 格式广度 | 打印 |
|---|---|---|---|---|---|---|
| XnView MP | 个人免费 | ✓ 标签页浏览器 | ✓ EXIF/IPTC/XMP 可编辑 | ✓ 含无损 JPEG 裁切 | ✓✓ 500+ 格式 | ✓ 独立模块 |
| GraphicConverter | €34.95 | ✓ ACDSee 式浏览器 | ✓ 全套 | ✓ | ✓✓ 200+ 格式 | ✓ |
| ACDSee Mac | 较贵 | ✓ 管理型 | ✓ | ✓ | ✓ RAW 强 | ✓ |
| Lyn | $19.95 | ✓ 轻量+地图视图 | ✓ EXIF/GPS/IPTC | ✓ 编辑检查器 | ✓ RAW/HDR | ◐ |
| ApolloOne | 免费+Pro | ✓✓ 文件夹快翻最快 | ✓ EXIF 详细 | ◐ 仅旋转等 | ✓ RAW 好 | ◐ 联系表为主 |
| Pixea | 免费+$6.99 | ◐ Plus 解锁缩略图面板 | ✓ 直方图+EXIF | ✗ 仅旋转翻转 | ✓ HEIC/PSD/RAW/WebP | ✗ |
| qView | 免费开源 | ◐ 顺序切换无缩略图墙 | ✗ 几乎无 | ◐ 极简 | ◐ 无 RAW | ✗ |
| Phoenix Slides | 免费开源 | ✓ 大量图片流畅 | ✓ EXIF | ✗ | ◐ 偏 JPEG | ✗ |
| 预览 Preview(系统) | 自带 | ◐ 侧栏凑合 | ✓ ⌘I 检查器 | ✓ 选框裁切 | ◐ RAW 有限 | ✓✓ 原生最佳 |

GPL-3.0 项目(禁止参考代码):FlowVision、nomacs、qView。可借鉴思路的 MIT 项目:imageviewer5、oculante。

### 关键结论

1. **五项全满足的只有 XnView MP 和 GraphicConverter**,但均为跨平台/老派风格,不够 Mac 原生
2. FastStone、光影看图、IrfanView 等 Windows 名将**均无官方 Mac 版**
3. Mac 原生阵营(ApolloOne/Lyn/Pixea/qView)**普遍砍掉打印**,裁切缺失或简陋
4. **打印是被集体忽视的差异化点** → MVP 主打:「ApolloOne 式文件夹快翻 + 完整 EXIF 面板 + 顺手裁切 + 正经打印(含多图拼版)」

---

## 五、主要信息来源

- Xcode 版本要求:developer.apple.com/xcode/system-requirements/、xcodereleases.com(2026-08 查证)
- Rust GUI 生态:腾讯云开发者社区《Rust GUI 框架全面对比与选型指南(2026)》、CSDN《7 大主流框架深度对比》(2026-04)、gpui.rs、zed.dev/releases、HN 讨论(Zed 放缓 GPUI)
- 竞品:howtoisolve / tenorshare / techbloat 的 2026 Mac viewer 横评、pleeq.com Top5、alternativeto.net、itutool.com 12 款推荐、ababtools(Phoenix Slides)
