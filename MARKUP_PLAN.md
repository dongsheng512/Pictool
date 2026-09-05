# 标记功能执行规格(给实现 agent)

> 状态:A1–A4 已落地,as-built 以仓库现有文件为准(2026-09-01,v0.4.1)。
> 本文件是文字标记 / 水印 / 画笔 / 马赛克的**规格与偏差说明**。总体项目规格见 `PLAN.md` + `AGENTS.md`。
> **不要**把本文的期号写成 `PLAN.md` 的 M1–M6。本文期号一律 **A1–A4**。
> **不要**再创建 `Annotation.swift` / `AnnotationMath.swift` / `WatermarkSpec.swift`——实现用的是下面 as-built 路径。

### As-built 文件(后续修改只动这些)

| 路径 | 职责 |
|---|---|
| `Sources/Pictool/Models/MarkupAnnotation.swift` | `Annotation` / `MosaicEffect` / `MarkPalette` / `MarkupGeometry` |
| `Sources/Pictool/Models/AnnotationStore.swift` | 进程内 `[URL: [Annotation]]` |
| `Sources/Pictool/Services/AnnotationRenderer.swift` | CoreText/CG 绘制,预览与导出同一 `draw` |
| `Sources/Pictool/Services/MarkupService.swift` | 已删除(0.6.13 清理死代码):实际烙印导出走 `CropService.encode` |
| `Sources/Pictool/Services/WatermarkService.swift` | `WatermarkSettings` / `WatermarkLayout` / `WatermarkRenderer` |
| `Sources/Pictool/Views/MarkupView.swift` | 标记 sheet |

约定偏差(已冻结,不要改回去):

- 文字锚点 = **块左上角**,不是基线中心。
- 调色盘 0=黑 1=白 2=红(默认) 3=黄 4=绿 5=蓝。浅色(白/黄)近黑描边,其余近白描边。
- `drawText` 的 `topLeft` 只接受**归一化**点。水印布局输出像素点,绘制前除以画幅。
- 水印画在裁切 **downscale 之后**(相对最终输出画幅)。
- Logo 复制到 `Application Support/PureView/watermark-logo.png`。

---

## 0. 实现 agent 必读(先做完再写代码)

1. 读 `AGENTS.md`、`PLAN.md` 第三节架构、本文全文。
2. 许可证红线:`FlowVision` / `iMonet` / `nomacs` / `qView` / `Art-Book` 均为 GPL-3.0,**禁止打开、参考、复制其代码**。思路可借鉴 MIT:`imageviewer5` / `Binder` / `oculante`。
3. 核心**零第三方依赖**。禁止 PencilKit、任何 SPM 包。文字用 CoreText,笔迹/马赛克用 CoreGraphics。
4. 部署 macOS 14+,Swift 6。纯 SPM,不建 xcodeproj。
5. 只测纯逻辑,不测 UI。命令:
   - 迭代:`swift build`
   - 单测:`DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test`
   - 单条:`… swift test --filter AnnotationMathTests`
6. 每期结束必须:`swift test` 全绿 + 升 `build.sh` 里 `CFBundleShortVersionString` + `README.md`「版本」小节追加一行 + `./build.sh`(产出 `build/PureView.app`)。
7. 注释:短、事实、只解释非显然约束。禁止用注释叙述「我做了什么」。禁止为未做的期写占位 TODO 实现。
8. 范围:只做当前期。A1 不得实现画笔/马赛克 UI。枚举里可以留 `stroke`/`mosaic` 关联值,但 A1 不得构造它们。
9. UI 文案用中文(与现有 CropView / 菜单一致)。
10. 导出式编辑:**永不默认写回原文件**。A1 标记 sheet 只提供「导出…」(另存)。覆盖原图不要做(那是裁切的特殊能力)。

当前版本:**v0.4.1**(A1–A4 已落地并完成验收修复)。历史期号:A1 0.4.0 / A2 原计划 0.4.1 / A3 0.4.2 / A4 0.4.3,实际四期并进 0.4.0。

---

## 1. 结论与顺序

| 期 | 版本 | 功能 | 预估 | 依赖 | 是否可跳过 |
|---|---|---|---|---|---|
| **A1** | 0.4.0 | 文字标记 sheet + 烙印导出 | 1–1.5d | 无 | 否,必须先做 |
| **A2** | 0.4.1 | 裁切导出面板:水印选项 | 0.5–1d | A1 的 stamp 钩子 | 可放到 A3 后, **不可插到 A1 前** |
| **A3** | 0.4.2 | 实线画笔(圈重点) | 1–1.5d | A1 模型 | 否(A4 依赖它) |
| **A4** | 0.4.3 | 马赛克/模糊(笔迹作蒙版) | 1–1.5d | A3 笔迹基建 | 否 |

硬顺序:**A1 → (A2 可选) → A3 → A4**。A2 相对画笔可延后,相对文字不可提前(否则要先挖空导出钩子)。

---

## 2. 冻结架构(四期共用,不许改)

### 2.1 坐标系

与 `CropMath` 相同:

- 归一化矩形/点:`0...1`
- **原点在图片左上**(与 `CGImage` 像素行序一致,与 SwiftUI 图片展示一致)
- 与分辨率无关

CG 绘制时坐标系默认左下原点。**所有 y 翻转只允许出现在 `AnnotationMath` 的纯函数里**,View 层禁止自己 `1 - y`。单测必须覆盖翻转。

### 2.2 统一模型

新建 `Sources/Pictool/Models/Annotation.swift`:

```swift
import Foundation
import CoreGraphics

struct Annotation: Identifiable, Equatable, Sendable {
    let id: UUID
    var kind: Kind

    enum Kind: Equatable, Sendable {
        case text(anchor: CGPoint, content: String, sizeLevel: Int, colorIndex: Int)
        case stroke(points: [CGPoint], widthLevel: Int, colorIndex: Int)
        case mosaic(points: [CGPoint], widthLevel: Int, effect: MosaicEffect)
    }
}

enum MosaicEffect: String, Equatable, Sendable {
    case pixelate
    case blur
}

enum AnnotationStyle {
    static let colors: [CGColor] = /* 见 §3 常量表,sRGB */
    static let textSizePerMille: [CGFloat] = [30, 50, 80]      // 相对图宽
    static let strokeWidthPerMille: [CGFloat] = [6, 12, 22]    // 相对图宽,A3
    static let mosaicWidthPerMille: [CGFloat] = [40, 70, 110]  // 笔刷直径,A4
    static let mosaicBlockPerMille: [CGFloat] = [12, 20, 32]   // 块大小,A4
}
```

规则:

- `sizeLevel` / `widthLevel` / `colorIndex` 都是档位下标,必须 `clamped` 到表长。
- `anchor` 是文字**基线中心**(水平居中、垂直大致在第一行基线)。命中用包围盒,不是单点。
- `stroke`/`mosaic` 的 `points` 为归一化折线,至少 2 点才有效。
- A1 只构造 `.text`。A3 构造 `.stroke`。A4 构造 `.mosaic`。
- **禁止**先写 `struct TextAnnotation` 再改枚举。

### 2.3 会话缓存(内存,不落盘)

新建 `Sources/Pictool/Models/AnnotationStore.swift`:

```swift
@MainActor
@Observable
final class AnnotationStore {
    private var items: [URL: [Annotation]] = [:]  // key = url.standardizedFileURL

    func annotations(for url: URL) -> [Annotation]
    func set(_ annotations: [Annotation], for url: URL)
    func update(_ annotation: Annotation, for url: URL) // 按 id 替换,没有则 append
    func remove(id: UUID, for url: URL)
}
```

- 关 sheet / 切图不丢。进程退出即丢。
- **禁止** sidecar 文件、禁止写 `~/Library` 标记库。
- 在 `PictoolApp` 用 `@State private var annotations = AnnotationStore()` 注入 `.environment(annotations)`,与 `FolderStore` 并列。

### 2.4 双路径统一渲染(生存级)

新建 `Sources/Pictool/Services/AnnotationRenderer.swift`:

唯一绘制入口(示意,A1 至少实现 text):

```swift
enum AnnotationRenderer {
    /// 在 `ctx` 里按 **像素坐标系、原点左上** 绘制。调用方保证 ctx 已是这个约定
    /// (见 AnnotationMath.makePixelContext)。
    static func draw(_ annotations: [Annotation], in ctx: CGContext, pixelSize: CGSize)

    /// 返回烙印后的新 CGImage(不修改原图)。
    static func stamp(_ annotations: [Annotation], onto image: CGImage) -> CGImage
}
```

硬性禁止:

- 预览用 SwiftUI `Text` 的 font 度量来摆位置,导出再用 CoreText(两端会漂)。
- 预览画一遍、导出再写一套路径。
- 字号用 pt/px 绝对值。必须用「图宽 × 千分比 / 1000」。

文字用 CoreText(`CTFramesetter` 或 `CTLine`)。颜色来自 `AnnotationStyle.colors`。

### 2.5 烙印在导出管线的位置

现有 `CropService.encode`(见 `Sources/Pictool/Services/CropService.swift`):

```
解码全尺寸 → CropTransform.apply → cropping(normalizedRect) → downscaled → 编码(EXIF/IPTC,GPS 开关)
```

改为:

```
解码全尺寸 → CropTransform.apply → cropping → **stamp annotations** → **watermark(A2)** → downscaled → 编码
```

A1 改动 `CropService.encode`,增加默认空参数,保持所有现有裁切调用能编译:

```swift
static func encode(..., includeGPS: Bool = true,
                   annotations: [Annotation] = [],
                   watermark: WatermarkSpec? = nil) throws -> Data
```

`watermark` 在 A1 可以先留参数但忽略,或 A1 不出现该参数、A2 再加。**推荐 A1 不加 watermark 参数**,避免空壳。A2 再加。

标记 sheet 自己导出(无裁切):

- `normalizedRect = CGRect(x:0,y:0,width:1,height:1)`(整图)
- `quarterTurns = initialQuarterTurns`(与裁切一样带入主视图旋转)
- `flipH/flipV/straighten = 0/false`(标记 sheet **不做**旋转/翻转/拉直 UI)
- `maxLongestSide = nil`
- `annotations = store.annotations(for: file.url)`

动图:只处理当前解码出的静帧/第一帧。不要逐帧烙印 GIF。

### 2.6 交互哲学

- 独立全窗口 sheet,对标 `CropView`(不要做主画布叠加层,以免和 `NSScrollView` 手势打架)。
- `FolderStore.isModalPresented = true` 期间,主窗口裸键必须失效(现有菜单已经 `.disabled(store.isModalPresented)`)。
- Esc 关闭 sheet(不导出)。
- 永不写回原文件(A1)。

---

## 3. 常量表(A1 起写死,禁止 View 里魔法数)

放在 `AnnotationStyle`:

| 档 | 含义 | 值 |
|---|---|---|
| 字号 0/1/2 | 相对图宽千分比 | 30 / 50 / 80 |
| 画笔宽 0/1/2 | 相对图宽千分比 | 6 / 12 / 22 |
| 马赛克刷 0/1/2 | 相对图宽千分比 | 40 / 70 / 110 |
| 马赛克块 0/1/2 | 相对图宽千分比 | 12 / 20 / 32 |

颜色(sRGB,不透明,index 0...5):

| index | 名 | RGB 0...1 |
|---|---|---|
| 0 | 白 | 1, 1, 1 |
| 1 | 黑 | 0.08, 0.08, 0.08 |
| 2 | 红 | 0.90, 0.18, 0.18 |
| 3 | 黄 | 0.98, 0.80, 0.12 |
| 4 | 绿 | 0.18, 0.72, 0.32 |
| 5 | 蓝 | 0.16, 0.48, 0.96 |

白/黄文字在浅图上需要描边才能看清。A1 规定:**所有文字描 1 档深色描边**,描边宽度 = `max(1pt, fontSize * 0.06)`(在像素空间)。描边颜色:浅色字(白/黄)用近黑;深色字(黑/红/绿/蓝)用近白。具体在 `AnnotationRenderer` 一处实现。

默认:颜色红(2),字号中(1)。

---

## 4. 纯函数 API(必须单测)

新建 `Sources/Pictool/Services/AnnotationMath.swift`。全部 `enum` + `static`,无 UI。

### 4.1 A1 必须实现

```swift
enum AnnotationMath {
    /// 归一化点 → 像素点(原点左上)。夹取到图像内。
    static func pixelPoint(normalized: CGPoint, pixelSize: CGSize) -> CGPoint

    /// 像素点 → 归一化点。
    static func normalizedPoint(pixel: CGPoint, pixelSize: CGSize) -> CGPoint

    /// 图宽千分比 → 像素尺寸。`perMille` 为 50 表示 5% 图宽。
    static func pixelLength(perMille: CGFloat, imageWidth: CGFloat) -> CGFloat

    /// 在「像素、原点左上」的位图上创建 CGBitmapContext,y 轴已经翻好转成左上原点。
    /// 调用方 draw 完用 makeImage()。失败返回 nil。
    static func makePixelContext(width: Int, height: Int) -> CGContext?

    /// 用 CoreText 度量文字(与 Renderer 同一套属性),返回归一化包围盒。
    /// `anchor` 为基线中心。盒子用于命中/拖拽,必须 ≥ 某最小命中尺寸(建议归一化 0.02)。
    static func textHitRect(anchor: CGPoint, content: String,
                            sizeLevel: Int, imageWidth: CGFloat, imageHeight: CGFloat) -> CGRect
}
```

单测写在 `Tests/PictoolTests/PictoolTests.swift` 新 class,命名示例:

- `AnnotationMathTests.testPixelPointCenter`
- `testNormalizedRoundTrip`
- `testPixelLengthFiftyPerMilleOn1000ptWidth` → 50
- `testTextHitRectContainsAnchor`
- `testTextHitRectClampsToUnitSquare`
- `testMakePixelContextOriginIsTopLeft`(画一个像素在 (0,0),读 CGImage 第一行确认;或画已知色块)

坐标例子(必须通过):

- 图 1000×800,归一化 (0.25, 0.25) → 像素 (250, 200)
- 图 1000 宽,perMille 50 → 50px

### 4.2 A3 追加

```swift
static func rdpSimplify(_ points: [CGPoint], epsilon: CGFloat) -> [CGPoint]
static func distancePointToSegment(point: CGPoint, a: CGPoint, b: CGPoint) -> CGFloat
static func strokeHit(points: [CGPoint], widthNormalized: CGFloat, at point: CGPoint) -> Bool
```

RDP epsilon 用归一化 0.002 作默认(A3 文档化)。点到线段距离 < `width/2 + 命中垫片(0.008)` 算命中。

### 4.3 A2 追加(可放 `WatermarkMath.swift`)

```swift
enum WatermarkAnchor: Int, CaseIterable { case topLeft, top, topRight, left, center, right, bottomLeft, bottom, bottomRight }

static func frame(imageSize: CGSize, markSize: CGSize, anchor: WatermarkAnchor, margin: CGFloat) -> CGRect
static func tiledFrames(imageSize: CGSize, markSize: CGSize, spacing: CGFloat, angleDegrees: CGFloat) -> [CGRect]
```

`margin` 用图宽的 3%(A2)。平铺在轴对齐盒子里旋转绘制,单测先测 `angle=0` 的网格,再测 45° 至少返回 >0 个框且不崩。

### 4.4 A4 追加

```swift
static func mosaicBlockSize(perMille: CGFloat, imageWidth: CGFloat) -> Int // ≥ 2
```

---

## 5. A1 文字标记 — 详细任务

目标版本 **0.4.0**。未完成前不要做 A2–A4 UI。

### 5.1 新建文件

| 文件 | 职责 |
|---|---|
| `Sources/Pictool/Models/Annotation.swift` | 模型 + `AnnotationStyle` |
| `Sources/Pictool/Models/AnnotationStore.swift` | 会话缓存 |
| `Sources/Pictool/Services/AnnotationMath.swift` | 纯函数 |
| `Sources/Pictool/Services/AnnotationRenderer.swift` | CoreText 绘制 + stamp |
| `Sources/Pictool/Views/MarkupView.swift` | 标记 sheet |

SPM `executableTarget` 会自动收录 `Sources/Pictool` 下新文件,不必改 `Package.swift`。

### 5.2 修改文件(精确挂钩)

**`FolderStore.swift`**

- 增加 `private(set) var markupRequestToken = 0`
- `func requestMarkup() { guard currentImage != nil else { return }; markupRequestToken += 1 }`
- `isModalPresented` 注释改为包含标记 sheet。

**`PictoolApp.swift`**

- `@State private var annotations = AnnotationStore()`
- `MainContentView().environment(store).environment(annotations)`
- 「图片」菜单,裁切按钮附近:

```swift
Button("文字标记…") { store.requestMarkup() }
    .keyboardShortcut("d", modifiers: [])
    .disabled(store.currentImage == nil || store.isModalPresented)
```

**`PureHeader.swift`**

- 在裁切按钮旁加:

```swift
HeaderButton("character.textbox", help: "文字标记 (D)",
             disabled: store.currentImage == nil) { store.requestMarkup() }
```

**`MainContentView.swift`**

对标裁切 sheet(约 251–262 行):

```swift
@State private var showMarkupSheet = false
// …
.sheet(isPresented: $showMarkupSheet) {
    if let file = store.currentImage {
        MarkupView(file: file, initialQuarterTurns: ((store.rotationCount % 4) + 4) % 4)
            .environment(annotations)
    }
}
.onChange(of: store.markupRequestToken) { _, _ in
    showMarkupSheet = store.currentImage != nil
}
.onChange(of: showMarkupSheet) { _, presented in
    store.isModalPresented = presented
}
```

注意:裁切 sheet 已经写 `isModalPresented`。两个 sheet 不会同时开(门禁)。**两个 onChange 都要写**,后关的那个把 flag 置 false。若同时存在,用:

```swift
store.isModalPresented = showCropSheet || showMarkupSheet
```

在两处 `onChange` 里都算这个或。推荐这一种,避免竞态。

**`CropService.encode`**

在 `cropping` 之后、`downscaled` 之前:

```swift
var canvas = cropped
if !annotations.isEmpty {
    canvas = AnnotationRenderer.stamp(annotations, onto: cropped)
}
let output = CropTransform.downscaled(canvas, longestSide: maxLongestSide ?? 0)
```

A1 裁切 sheet **先不传 annotations**(默认 `[]`),行为与现在完全一致。标记导出走「整图 rect + annotations」。

现有 `CropView.export` 调用不必改(有默认参数)。`MarkupView` 新调用传入 annotations。

### 5.3 MarkupView 行为规格

布局对标 `CropView`:顶栏 / 画布 / 底栏,`.frame(minWidth: 820, minHeight: 560)`。

**顶栏**

- 6 色圆点(当前档描边高亮)
- 3 档字号:小/中/大
- 删除(选中才可用)
- 撤销 ⌘Z(按钮+快捷键)
- Spacer
- 「导出…」主按钮(有至少一条文字才可用)
- 「完成」关闭(不导出,缓存保留)

**画布**

- 预览图:用 `ImageLoader.decode(url:maxPixelSize: 1500)` 得到位图,再按 `initialQuarterTurns` 用 `CropTransform.apply`(只转、不翻不拉直)显示。与裁切预览同源。
- 图片 `aspectRatio` fit 居中。点击坐标必须换算到归一化:先把点击映射到 fit 矩形内,再 `/ size`。
- 点空白:进入输入态,在点击处弹出单行 `TextField`(可先用 overlay 固定在点击附近)。回车:content 去空白后非空则 `append` `.text`,否则取消。Esc:取消输入态。
- 输入态期间禁用画布点击添加第二条。`FocusState` 为 true 时,把 ⌘Z / 删除键让给系统(对标 `CropView.editingCustomRatio`)。
- 点已有文字(命中 `textHitRect`):选中。拖动改 `anchor`(拖的是归一化点,松手 clamp 0...1)。
- 选中时画包围盒(1px 白+黑,别挡字)。
- Delete / Backspace:删除选中图元(输入态除外)。
- ⌘Z:弹出图元数组上一快照。实现:`undoStack: [[Annotation]]`,每次提交/移动结束/删除 push。不做字符级撤销。不做重做也可以(A1 可不做 ⌘⇧Z;若做,对标 CropView 的 redoStack)。
- 中文 IME:必须实机验证「拼音上屏 + 回车提交」。若回车被 IME 吃掉,用工具栏「确定」按钮作为并列提交,回车在 `onSubmit` 再绑一次。

**底栏**

- 导出格式 / 质量:抄 `CropView.bottomBar` 的格式选择与 JPEG/HEIC 质量滑杆。
- Toggle「包含位置信息」,默认 true,传 `includeGPS`。
- 不要「覆盖原图」。不要最长边(A1 省略,保持简单)。

**导出**

- `NSSavePanel`,默认文件名 `原名-标记.ext`,不允许无确认覆盖原路径(如果用户硬选原路径,`NSSavePanel` 自己确认即可;不要做 CropView 那套原子覆盖)。
- 后台 `Task.detached` 调 `CropService.encode`。失败 `alert`。

**旋转**

- 只消费 `initialQuarterTurns`,sheet 内不提供再转。标记坐标定义在「带入旋转之后的图幅」上,与裁切选区语义一致。

### 5.4 A1 明确不做

- 画笔、马赛克、形状、箭头
- sheet 内翻转/拉直
- 覆盖原图
- 水印
- sidecar
- 主画布手势叠加
- 动图逐帧

### 5.5 A1 完成定义(全部满足才许升 0.4.0)

- [ ] `swift test` 全绿,且新增 `AnnotationMathTests` 至少 5 条
- [ ] 菜单「文字标记…」、顶栏按钮、裸键 D 能打开 sheet;无图或已有模态时 disabled
- [ ] 打开 sheet 时 `isModalPresented == true`,主窗口 I/C/F/空格/←→ 不生效
- [ ] 点空白 → 输入中文 → 回车出现文字;Esc 取消输入
- [ ] 拖动文字、删除、⌘Z 可用
- [ ] 关 sheet 再开,同一张图文字还在;换图各自独立
- [ ] 导出 PNG,用预览.app 打开,文字位置/相对大小与 sheet 内目视一致(人工)
- [ ] 原文件未被修改
- [ ] `build.sh` 版本 0.4.0,README 追加一行,`./build.sh` 成功

### 5.6 A1 工作分段(agent 按段提交更稳)

**段 1(先合,无 UI):** Annotation + Style + Math + Renderer.stamp 能把文字烙到纯色 CGImage 上 + 单测绿。可用临时测试:造 200×100 红底,烙「测」后读像素非纯红。

**段 2:** MarkupView + 入口挂钩 + CropService stamp 参数 + 导出。然后升版打包。

---

## 6. A2 导出水印

版本 **0.4.1**。依赖 A1 的 `stamp` 已在 cropping 之后。

### 6.1 落点

**只改裁切导出底栏**(`CropView.bottomBar`),与「包含位置信息」并列。不做画布摆放。不做独立「纯导出」入口(二期)。

### 6.2 模型

`Sources/Pictool/Models/WatermarkSpec.swift` + `AppPreferences` 风格 storageKey:

```swift
struct WatermarkSpec: Equatable {
    var enabled: Bool
    var text: String                 // 空则只用水印图(若有)
    var opacity: Double              // 0.15...1,默认 0.35
    var anchor: WatermarkAnchor      // 默认 bottomRight
    var tiled: Bool                  // 默认 false
    var tileSpacingPerMille: CGFloat // 默认 80
    var tileAngle: Double            // 默认 -30
    var imagePNG: Data?              // 用户选的 logo,可空;不要把大图放 UserDefaults,路径 bookmark 或 Application Support 文件
}
```

Logo 文件:复制到 `Application Support/PureView/watermark-logo.png`,偏好里只存「是否有 logo」。不要把 PNG Data 塞 UserDefaults。

文字水印默认内容:空字符串,占位提示「水印文字」。空且无 logo 时,即使 enabled 也不绘制。

### 6.3 管线

`CropService.encode` 增加 `watermark: WatermarkSpec? = nil`。

顺序:**annotations stamp → watermark → downscale**。水印压在标记上。

绘制进 `AnnotationRenderer` 或新建 `WatermarkRenderer`,但必须走像素左上 ctx,与标记同一 `makePixelContext`。

### 6.4 UI

CropView 底栏增加:

- Toggle「水印」
- 展开后:文字框、透明度滑杆、九宫格 Picker(3×3 或菜单九项)、平铺开关
- 「选择 Logo…」`NSOpenPanel` 限 png
- 勾选水印时,导出即使选区是整图也会烙印

裁切调用 `encode` 时传入当前偏好。标记 sheet A2 **不必**加水印控件(避免两处配置)。若 A2 有余力,MarkupView 导出也可读取同一 `WatermarkSpec`(同一 UserDefaults),不另做 UI。

### 6.5 单测

- 九宫格:1000×1000 图画 100×50 标,`bottomRight`+margin 30 → origin 靠近 (870, 920) 量级,且 `maxX≤1000`,`maxY≤1000`
- 平铺 angle=0:返回多个不重叠的框(允许 spacing)
- enabled 但 text 空且无图:frame 列表为空

### 6.6 A2 不做

- 画布手摆水印
- 无裁切的独立导出入口
- 把水印写进 Annotation 枚举(水印是导出策略,不是图元)

---

## 7. A3 画笔

版本 **0.4.2**。在 **同一个 MarkupView** 上长工具条,不要新 sheet。

### 7.1 工具状态

```swift
enum MarkupTool: Equatable { case text, pen, eraser, mosaic }
```

A3 实现 `text | pen | eraser`。`mosaic` 到 A4 再出现在工具条。

每期只让一个新工具可点。

### 7.2 笔迹

- 鼠标拖出归一化点列。采样:视图坐标每次移动都记,松手后 `rdpSimplify(epsilon: 0.002)`。
- 无压感。线宽档 `strokeWidthPerMille`。颜色共用 6 色。
- 平滑:RDP 之后可选 Catmull-Rom 细分再画;命中检测用抽稀后的折线,不要用细分后的密点。
- 橡皮:`MarkupTool.eraser` 在按下时找命中的 **整段** `.stroke`(以及 A4 的 `.mosaic`),删除该 Annotation。不是像素橡皮。
- 撤销:与文字共用 undo 栈(整份 `[Annotation]` 快照)。

### 7.3 绘制

`AnnotationRenderer.draw` 增加 stroke:`CGContext` 圆角线帽 `round`,折线 stroke。宽度 = `pixelLength(strokeWidthPerMille[level], imageWidth)`。

### 7.4 单测

- RDP:共线三点变两点
- `distancePointToSegment` 点在中点上为 0,端点外垂足夹取
- `strokeHit` 在线宽内 true、远离 false

### 7.5 A3 不做

- 压感、毛笔、填充
- 像素级橡皮
- PencilKit

---

## 8. A4 马赛克/模糊

版本 **0.4.3**。工具条加「马赛克」,效果二选一(默认 pixelate)。

### 8.1 模型

只存 `.mosaic(points, widthLevel, effect)`。**禁止**把像素化后的 bitmap 放进 Annotation。

### 8.2 渲染(WYSIWYG)

对当前 `pixelSize` 的底图:

1. 生成一张全图效果层:pixelate = 先缩到 `ceil(width/block)` 再放大(nearest);blur = `CIGaussianBlur` 或 `CGContext` 等效,半径与 block 同量级。
2. 效果层每张图、每个 pixelSize **只算一次**(preview 1500 算一次,export 全尺寸另算一次,不要用预览层去导出)。
3. 按每条 mosaic 折线建成粗线 path(圆帽,直径 `mosaicWidthPerMille`),clip 后把效果层画上去。

块大小:`mosaicBlockPerMille`,相对**当前绘制图像的宽度**,所以 1500px 预览和 6000px 导出颗粒度相对图宽一致。

### 8.3 橡皮

与 A3 相同:命中 mosaic 折线则删整段 Annotation。底图像素从未被改写。

### 8.4 单测

- `mosaicBlockSize(20, 1000) == 20`
- `mosaicBlockSize(12, 100) >= 2`
- 归一化宽度换算与 stroke 同一 `pixelLength`

### 8.5 A4 不做

- 矩形选区马赛克(只要涂抹)
- 人脸检测
- 把效果层缓存进磁盘

---

## 9. 快捷键与门禁

现有裸键(不要占用):`I` 信息、`C` 裁切、`F` 只看图、`0`/`1` 缩放、`←`/`→` 切图、空格幻灯片、`D` **本功能占用(文字标记)**。

Sheet 内:

| 键 | 行为 |
|---|---|
| Esc | 输入态→取消输入;否则关 sheet |
| Return | 提交输入 |
| ⌘Z | 撤销图元(非输入态) |
| Delete | 删除选中 |
| ⌘S 或顶栏导出 | 导出(不要抢系统保存除非按钮标明) |

`isModalPresented` 为 true 时主窗口这些裸键全部 disabled(现有模式,照抄裁切)。

---

## 10. 版本与 README

改 `build.sh` 中:

```xml
<key>CFBundleShortVersionString</key><string>0.4.0</string>
```

`README.md`:

- 标题 `# PureView v0.4.0`
- 「版本」列表顶部追加一行,例如:
  - `v0.4.0` — 文字标记:独立 sheet,点放/拖动/删除/撤销,6 色 3 档,烙印导出(不写回原图)
- 「功能」或「结构」可补 `Annotation.swift` / `MarkupView.swift` 一行,保持简短

结构目录若更新,与现有树风格一致(见 README 现树)。

---

## 11. 验收时 agent 自测清单(每期)

```
swift build
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
./build.sh
```

人工(A1):打开一张 JPEG → D → 点图输入「测试」回车 → 拖到角落 → 导出 PNG → Preview 打开对比;再确认原 JPEG 修改日期未变。

---

## 12. 明确不做(全期)

- 签名级压感笔迹 / PencilKit / 第三方库
- sidecar 持久化、云同步
- 便签、箭头、矩形、箭头家族(将来箭头可另开一期,不在 A1–A4)
- 多图层管理
- 透视校正、批量裁切、批量加水印文件夹
- 主视图 NSScrollView 上直接涂鸦
- 参考或复制 GPL 项目代码

---

## 13. 现有代码锚点(避免搜错)

| 用途 | 位置 |
|---|---|
| 裁切 sheet 挂钩 | `MainContentView.normalLayer` 约 251–262 行 |
| isModalPresented | `FolderStore` ~54–56 行;菜单 `PictoolApp` `.disabled(store.isModalPresented)` |
| requestCrop | `FolderStore.requestCrop` ~610 |
| 导出管线 | `CropService.encode` ~354–406 |
| 归一化先例 | `CropMath.pixelRect` |
| 预览 1500px | `CropView` 注释与 `loadPreview` |
| 旋转带入 | `CropView(file:initialQuarterTurns:)` |
| 顶栏按钮 | `PureHeader.rightCluster` 裁切按钮旁 |
| 版本号 | `build.sh` `CFBundleShortVersionString` 现为 0.3.2 |
| 偏好 storageKey 模式 | `Sources/Pictool/Models/AppPreferences.swift` |

---

## 14. 给执行 agent 的最小开场指令

A1–A4 已在 v0.4.0 落地,v0.4.1 修了命中盒/水印坐标/会话缓存等验收缺陷。后续 agent **不要**从 A1 段 1 重建文件。

若继续改标记/水印:

1. 只改 as-built 表里的路径。
2. 文字命中必须走 `MarkupGeometry.textHitRect`(归一化)。禁止把 `textSize` 像素尺寸直接塞进以 0...1 为原点的 `CGRect`。
3. 水印必须先把 CG 上下文翻成 y 向下,再按 `WatermarkLayout.origin` 摆;文字进 `drawText` 前换成归一化点。
4. 改纯函数就补 `Tests/PictoolTests/PictoolTests.swift`。功能合入升 `build.sh` 版本并写 README「版本」一行。
