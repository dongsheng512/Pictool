# Pictool 开发计划

> 图片查看器(macOS)· Swift 6 + SwiftUI(混合 AppKit)
> 制定日期:2026-08-22

---

## 一、环境与结论速览

| 项目 | 情况 |
|---|---|
| 运行环境 | macOS 15.7 (arm64) |
| 工具链 | Xcode 26.3 (Swift 6.2),`xcode-select` 当前指向 CommandLineTools |
| 部署目标建议 | **macOS 14.0+**(可用 `@Observable`、新式 Gesture;当前机器 15.7 满足) |
| 第三方依赖 | **核心功能零依赖**,仅 SVG 等矢量格式按需引入(可选) |

**总体评估:五个需求全部可行,难度中等偏低。** 最大工作量在"文件夹浏览 + 缩略图 + 流畅缩放"的体验打磨和裁切的坐标换算;格式支持因 ImageIO 原生覆盖极广,几乎是免费达成。

---

## 二、需求逐项技术评估

### 需求 1:文件夹浏览 / 切换 / 缩略图 —— ✅ 可行,核心工作量所在

- 选文件夹:`NSOpenPanel`(AppKit,比 SwiftUI `fileImporter` 在 macOS 上更可靠);支持同时打开多个文件夹,在左侧边栏形成"项目文件夹"列表,可展开各自的子文件夹。
- 枚举:`FileManager.enumerator` + `UTType(identifier:)?.conforms(to: .image)` 过滤;`localizedStandardCompare` 自然排序(img2 < img10)。
- 缩略图:`CGImageSourceCreateThumbnailAtIndex` 生成(不整图解码,内存友好),`NSCache` 缓存 + 后台队列串行生成,`LazyVGrid` 网格展示于左侧边栏下半区。
- 主视图:**用 `NSViewRepresentable` 包 `NSScrollView + NSImageView`**(AppKit 混合的核心点)——免费获得触控板捏合缩放、滚轮平移、像素级 zoom、惯性滚动。纯 SwiftUI 手势方案体验明显不如它。
- 切换:←/→ 键、边栏缩略图点击、两端循环可选;切换时网格自动滚动到当前项。

### 需求 2:图片信息查看 —— ✅ 可行,低风险

- 元数据:`CGImageSourceCopyPropertiesAtIndex` 一站式拿到 EXIF / TIFF / IPTC / GPS / 颜色空间 / 位深 / DPI / 帧数。
- 文件信息:`URLResourceValues`(大小、创建/修改时间)+ 路径。
- 展示:右侧 Inspector 面板(可折叠),分组树形列表,支持复制。

### 需求 3:简单裁切 —— ✅ 可行,注意坐标换算

- 交互:进入裁切模式后,在按屏幕适配(fit)缩放的 SwiftUI 画布上叠加可拖拽/可调 8 手柄的选区矩形;提供比例预设(自由 / 1:1 / 4:3 / 16:9)并实时显示像素尺寸。
- 执行:`CGImage.cropping(to:)`,需要做 **屏幕坐标 → 像素坐标** 换算(fit 缩放比 + 翻转 + 取景框裁剪),这是唯一需要写单测的数学。
- 导出:`NSSavePanel` 另存(默认不覆盖原文件,覆盖需确认);格式选 PNG/JPEG/HEIC/TIFF;用 `CGImageDestinationCopyImageSource` 尽量保留 EXIF。

### 需求 4:格式支持多 —— ✅ 基本免费(已实测)

在本机(macOS 15.7)实测 `CGImageSourceCopyTypeIdentifiers()` 共 **61 种原生可解码格式**:

- **日常格式**:JPEG、PNG、GIF(含动画)、HEIC/HEIF(含动画 heics)、TIFF、BMP、ICO/ICNS、WebP、**AVIF**、**JPEG XL**、JPEG 2000、PICT
- **专业/工程**:PSD(合成预览)、OpenEXR、DDS、TGA、SGI、PBM 族、Radiance HDR、ASTC/KTX 纹理
- **全系相机 RAW**:CR2/CR3、NEF/NRW、ARW/SR2、RAF、RW2、ORF、DNG、3FR/FFF、RWL 及宾得/适马/飞思等

编码(导出)支持 21 种:PNG、JPEG、HEIC、TIFF、BMP、GIF、ICO、ICNS、PDF 等;**WebP/AVIF 仅解码、不可编码**(裁切导出用 PNG/JPEG/HEIC 即可)。

结论:**无需第三方库即覆盖 99% 场景**。缺口仅 SVG(矢量)与超高清 JXL 实际解码质量,均列为可选扩展,不进核心范围。

### 需求 5:打印 —— ✅ 可行,半天工作量

- SwiftUI 在 macOS 上无打印 API,走 AppKit `NSPrintOperation` + 标准打印面板(自带页面预览)。
- 提供"适配页面 / 实际大小"两种缩放,按图片宽高比自动建议横/纵向。

---

## 三、架构设计

### 模块划分(SPM 可复用层 + App 薄壳)

```
Pictool/
├── Package.swift              # SPM:executable 目标,零外部依赖
├── build.sh                   # swift build -c release + 组装 Pictool.app(ad-hoc 签名)
├── Sources/Pictool/
│   ├── PictoolApp.swift       # @main App、窗口、工具栏
│   ├── Models/
│   │   ├── ImageFile.swift        # 单图模型:URL、格式、尺寸、元数据(懒加载)
│   │   ├── FolderStore.swift      # @Observable:文件夹树(多根)、各文件夹图片列表/排序/当前索引/预取
│   │   └── ThumbnailProvider.swift# 缩略图生成 + NSCache
│   ├── Views/
│   │   ├── MainContentView.swift  # NavigationSplitView 三栏布局:边栏 + 主视图 + Inspector
│   │   ├── ImageViewCanvas.swift  # NSViewRepresentable: NSScrollView+NSImageView(缩放/平移)
│   │   ├── SidebarView.swift      # 左侧边栏:上半区文件夹树,下半区缩略图网格
│   │   ├── ThumbnailGridView.swift# 缩略图网格(异步加载、当前项高亮、跟随滚动)
│   │   ├── InfoInspector.swift    # 信息面板
│   │   ├── CropView.swift         # 裁切模式(独立 SwiftUI 画布 + 选区叠加层)
│   │   └── Toolbar.swift
│   └── Services/
│       ├── ImageLoader.swift      # 解码、降采样、按需加载全尺寸
│       ├── MetadataService.swift  # CGImageSource 属性解析
│       ├── CropService.swift      # 坐标换算 + 裁切 + 导出(保元数据)
│       └── PrintService.swift     # NSPrintOperation 封装
└── Tests/PictoolTests/            # 坐标换算、自然排序、格式识别单测
```

### 主界面布局(三栏 + 状态栏)

```
┌──────────────────────────────────────────────────────────────┐
│ 工具栏: ⌘O 打开 | ← | → | 缩放% | 信息 | 裁切 | 打印           │
├───────────────┬──────────────────────────────────┬───────────┤
│ 左侧边栏(可折叠)│                                  │ 信息面板    │
│ ▾ 项目文件夹     │                                  │ (可折叠)  │
│   ▸ 2024-日常   │       主视图缩放平移画布            │           │
│   ▸ 2025-旅行   │    (NSImageView + NSScrollView)  │           │
│ ▸ 下载/壁纸     │                                  │           │
│ ─────────────│                                  │           │
│ 缩略图网格      │                                  │           │
│ ▣ ▣ ▣ ▣       │                                  │           │
│ ▣ ▣ ▣ ▣       │                                  │           │
│ (当前项高亮框)  │                                  │           │
├───────────────┴──────────────────────────────────┴───────────┤
│ 状态栏: 文件名.jpg · 4032×3024 · 12/48 · 缩放 100%            │
└──────────────────────────────────────────────────────────────┘
```

- 整体采用 `NavigationSplitView`(边栏 + 详情)+ `.inspector` 尾随面板(macOS 14+),边栏与信息面板均可折叠、可拖宽。
- **边栏上半区——项目文件夹树**:打开过的文件夹作为根节点列表(含"打开其他文件夹…"入口),可展开子文件夹;点选某文件夹后,下半区网格与主视图切换到该文件夹的图片。
- **边栏下半区——缩略图网格**:`LazyVGrid` 自适应 2~4 列(随边栏宽度),异步加载 + 当前项高亮描边;←/→ 切换时网格自动滚动跟随。
- 底部为轻量状态栏(当前文件、序号、缩放比例);原"底部缩略图条"方案由边栏网格替代。

### SwiftUI / AppKit 分工

| 职责 | 技术 |
|---|---|
| 窗口(NavigationSplitView 三栏)、工具栏、左侧边栏(文件夹树+缩略图网格)、信息面板、裁切 UI、快捷键 | SwiftUI |
| 主视图缩放平移画布 | AppKit(`NSScrollView`/`NSImageView` 经 Representable 包装) |
| 文件/文件夹选择、另存为 | AppKit(`NSOpenPanel`/`NSSavePanel`) |
| 打印 | AppKit(`NSPrintOperation`) |

### 性能与内存策略

- 缩略图:按需生成 + `NSCache`,峰值占用可控(如 256px ≈ 每张 256KB)。
- 主图:先按 `屏幕尺寸×2` 降采样解码用于浏览;**仅当缩放超过阈值或进入裁切/打印/导出时才解码全尺寸**,超清大图(>100MP)浏览不落全尺寸。
- 相邻预取:后台预解码前后各 1 张,切换零等待。
- 内存红线:常规 1000 张照片文件夹浏览,内存目标 < 500MB。

---

## 四、风险与对策

| 风险 | 等级 | 对策 |
|---|---|---|
| 裁切屏幕↔像素坐标换算出错 | 中 | 换算逻辑独立成纯函数 + 单元测试 |
| 超大图(全景、亿级像素)内存压力 | 中 | 降采样浏览 + 全尺寸按需加载;>100MP 走分块解码(二期) |
| GIF/动态 WebP 不动(SwiftUI Image 不播动画) | 中 | 用 `CGAnimateImageAtURL` 驱动帧回调更新;GIF 为主,动态 WebP/HEICS 实测为准 |
| RAW 显示为嵌入预览而非全解码(画质略低) | 低 | 默认预览足够;全质量可后续接 `CIRAWFilter` |
| 无 xcode-select 指向完整 Xcode | 低 | 用 SPM + `build.sh` 纯 CLI 构建,不依赖 xcodeproj |
| 文件夹内容变化(增删)不同步 | 低 | 一期手动刷新;二期 `DispatchSource` 监听目录 |

---

## 五、里程碑计划(预估 ~9 人日;与 AI 结对约 4 个工作段)

> **进度(2026-08-22):M0–M4 已完成并验证;M5 完成动图播放与拖拽打开;M6 完成 14 项单元测试与打包脚本。待办:App 图标、偏好设置、真实照片库 dogfood。**

| 阶段 | 内容 | 预估 | 验收标准 | 状态 |
|---|---|---|---|---|
| **M0 脚手架** | SPM 工程、App 骨架、窗口与工具栏占位、`build.sh` 打包 | 0.5d | `./build.sh` 产出 Pictool.app 并可启动 | ✅ |
| **M1 浏览核心** | 打开/添加文件夹、文件夹树、NSImageView 画布(缩放/平移/适配/100%)、←/→ 切换、边栏缩略图网格(异步+缓存+高亮+跟随滚动)、状态栏、相邻预取 | 2.5d | 1000 张文件夹流畅浏览,内存 < 500MB;切换文件夹网格即刷新 | ✅ |
| **M2 信息面板** | 文件+图像+EXIF/GPS 分组展示、复制、折叠 | 1d | JPEG/HEIC/RAW 均能显示拍摄参数 | ✅ |
| **M3 裁切** | 裁切模式(选区、手柄、比例预设、像素尺寸)、坐标换算单测、另存导出(PNG/JPEG/HEIC/TIFF,保 EXIF) | 1.5d | 裁切结果与选区像素一致(单测+人工比对) | ✅ |
| **M4 打印** | NSPrintOperation 集成、适配页面/实际大小、Cmd+P | 0.5d | 打印面板预览正确(A4 横/纵) | ✅ |
| **M5 格式与体验** | 动图播放(GIF 优先)、拖拽打开文件/夹、深色模式打磨、App 图标、最近文件夹、偏好设置(排序/背景色) | 2d | 61 种原生格式全部可开;GIF 流畅播放 | 🔶 动图✅ 拖放✅ 图标/偏好待做 |
| **M6 测试发布** | 单测补全、真实照片库 dogfood、release 打包 + ad-hoc 签名 | 1d | release 版从 /Applications 正常运行 | 🔶 14 项单测✅ dogfood 待做 |

关键快捷键:←/→ 切换、+/- 缩放、0 适配窗口、1 实际大小、I 信息、C 裁切、⌘O 打开、⌘P 打印。

---

## 六、已定的技术决策(默认采用,可推翻)

1. **构建体系:SPM + `build.sh` 打包脚本**,不手写 xcodeproj;需要 IDE 调试时 `Package.swift` 可直接在 Xcode 打开。(备选:后续如需上架/签名分发再转 xcodeproj。)
2. **部署目标 macOS 14.0**,不沙盒(本地工具定位);日后上架再补安全书签。
3. **核心零第三方依赖**;SVG、JXL 高画质、WebP 编码等列为可选扩展,不阻塞主线。

## 七、暂不做(二期候选)

矢量 SVG 渲染、>100MP 分块解码、文件夹实时监听、全质量 RAW 解码(`CIRAWFilter`)、批量操作、收藏/标签、对比视图。

---

## 八、竞品概览(2026-08 调研)

| 应用 | 形态 | 覆盖本项目需求的情况 |
|---|---|---|
| 预览(系统) | 免费 | 能看/裁切/打印,但无文件夹缩略图网格、切换笨拙、EXIF 弱 |
| [Pixea](https://apps.apple.com/us/app/pixea/id1507782672?mt=12) | App Store,订阅/买断 | 格式极全(含 JXL/PSD/RAW/视频)+ 编辑,但收费 |
| [ApolloOne](https://www.apollooneapp.com/) | App Store,免费+内购 | 摄影师向,RAW 极快、EXIF 编辑,偏重、商业 |
| Phiewer / Lyn / Fileloupe | 收费 | 浏览体验好,轻量或偏管理器,不满足全部五项 |
| XnView MP | 免费(Qt 跨平台) | 功能全但非原生 Mac,更像管理器 |

**开源·macOS 原生(Swift):**

| 项目 | Star | 许可证 | 维护 | 覆盖情况 |
|---|---|---|---|---|
| [netdcy/FlowVision](https://github.com/netdcy/FlowVision) | 1.3k | GPL-3.0 | 活跃 | 瀑布流缩略图网格、类 Finder 文件管理、视频、HDR;无 EXIF/裁切/打印 |
| [wflixu/iMonet](https://github.com/wflixu/Monet) | 25 | GPL-3.0 | 活跃 | 文件夹浏览/缩略图侧栏/动图/打印;无裁切、EXIF 不完整、不支持 RAW |
| [lambdan/imageviewer5](https://github.com/lambdan/imageviewer5) | 44 | MIT | 活跃 | 极简快速浏览,无裁切/EXIF/打印 |
| [claration/Binder](https://github.com/claration/Binder) | 27 | MIT | 一般 | 轻量浏览(因 Art-Book 年久失修而重写),无裁切/EXIF/打印 |
| [xjbeta/Art-Book](https://github.com/xjbeta/Art-Book) | 24 | GPL-3.0 | 停滞 | 早期浏览项目,已被后来者替代 |

**开源·跨平台(可在 macOS 运行):**

| 项目 | 语言 | 许可证 | 覆盖情况 |
|---|---|---|---|
| [woelper/oculante](https://github.com/woelper/oculante) | Rust | MIT(部分 LUT 资源 GPL) | **最接近的现成方案**:EXIF✅、非破坏裁切(JPEG 可免重压缩)✅、格式极多(JXL/AVIF/SVG/DICOM/QOI/部分 RAW)✅;无打印、无缩略图网格;macOS 需装 libheif;处于维护模式(重写中) |
| [nomacs/nomacs](https://github.com/nomacs/nomacs) | C++/Qt | GPL-3.0 | 浏览/缩略图/EXIF/RAW/PSD✅,双屏同步对比特色;有 macOS arm64 构建;无裁切/打印 |
| [jurplel/qView](https://github.com/jurplel/qView) | C++/Qt | GPL-3.0 | 极简流畅;无缩略图/裁切/信息面板 |
| [ArturKovacs/emulsion](https://github.com/ArturKovacs/emulsion) | Rust | MIT | **已停更** |

**结论:开源领域同样没有「五项需求全覆盖」的现成方案。** 最接近的两个:oculante(缺打印和缩略图,非原生,Rust)与 iMonet(缺裁切/完整 EXIF/RAW,GPL)。Swift 原生且 MIT 的项目都是几十星级的纯浏览工具。Pictool 的定位空档进一步坐实。

对开发的三点影响:
1. 若不介怀非原生 UI 和无打印,**oculante 是当前可直接安装使用的最优开源替代**,建议先试用它再决定是否自研。
2. **许可证红线:FlowVision、iMonet、nomacs、qView、Art-Book 均为 GPL-3.0,不得参考/复制其代码**;可参考的 MIT 项目为 oculante(Rust)、imageviewer5、Binder。
3. 可吸收的功能点:oculante 的 JPEG 无损裁切(免重压缩)与非破坏编辑栈、FlowVision 的瀑布流网格与大目录性能优化、nomacs 的双屏同步浏览(均为二期候选)。
