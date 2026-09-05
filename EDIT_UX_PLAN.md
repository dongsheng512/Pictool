# 编辑器交互升级执行规格(给实现 agent)

> 状态:**B0–B4 已全部落地**(B0 v0.5.26–0.5.36;B1 0.6.0 / B2 0.6.1 / B3 0.6.2 / B4 0.6.3,2026-09-05)。本文期号 **B0–B4**,不要和 `MARKUP_PLAN.md` 的 A1–A4、`PLAN.md` 的 M1–M6 混用。
> B1 as-built:`EditCanvasMath.swift`(Models);手势全部挂在 `CanvasMouseCatcher`(scrollWheel/magnify/空格键本地监听),`MarkupCanvas` 接 zoom/pan 并回传容器尺寸。
> B2 as-built:`ShapeKind` + `.shape(kind:from:to:widthLevel:colorIndex:)`;几何纯函数在 `MarkupGeometry`;实时预览走 SwiftUI Path,提交后进统一渲染器。
> B4 as-built:`text.sizeFraction`(连续,三档 chip 为预设,`clampTextFraction` 夹取 0.015–0.120)+ 选中框右下角手柄拖拽;荧光笔 = `.stroke(..., style: StrokeStyleKind)`,渲染 alpha 0.45 + `highlighterWidths` 表,H 键切换。
> 对标交互参考:**macOS 预览(Preview.app)的标记工具栏**——只借鉴交互模型,不看它的代码。
> 基线:仓库现有统一编辑器 `Sources/Pictool/Views/EditView.swift`(预览.app 式单行工具条 + 归一化标注)。
> 版本节奏**由用户决定**:每期合入时同步 `build.sh` 的 `CFBundleShortVersionString` + `README.md`「版本」小节,具体号用户说了算。

---

## 0. 实现 agent 必读(先做完再写代码)

1. 读 `AGENTS.md`、`MARKUP_PLAN.md` 全文(标注模型的冻结约定在它第 2、3 节)、本文全文。
2. 许可证红线不变:FlowVision / iMonet / nomacs / qView / Art-Book 均 GPL-3.0,禁止参考;可借鉴思路的 MIT 项目:imageviewer5 / Binder / oculante。
3. 核心**零第三方依赖**,禁止 PencilKit / 任何 SPM 包。文字 CoreText,图形 CoreGraphics,缩放平移事件用 AppKit(`NSView` 覆盖 `scrollWheel` / `magnify`)。
4. 部署 macOS 14+,Swift 6,纯 SPM。
5. 只测纯逻辑(缩放视口数学、形状几何、命中测试),不测 UI。命令:
   - 迭代:`swift build`
   - 单测:`swift test`;单条:`swift test --filter EditCanvasMathTests`
6. 每期结束:`swift test` 全绿 + 版本同步 + `./build.sh` 打包。
7. 注释短、事实、只解释非显然约束;UI 文案中文;范围只做当前期。
8. 标注数据**只在内存**(`AnnotationStore`,不落盘),所以 `Annotation.Kind` 关联值可以直接改形状,没有持久化迁移负担——但改模型时必须同步渲染器、命中测试、选区 bounds 三处。

---

## 1. 现状分析(为什么做这四期)

### 1.1 已经做对的(保持,不要重做)

- 单行工具条 + 属性随工具上下文切换(颜色/大小/效果 chip 只在相关工具出现)——与预览.app「选中标注 → 上下文格式栏」同构。
- 统一撤销栈、方向键微调、双击改文字、Esc 分层退出(草稿 → 选中 → 无)、会话级标注缓存(`AnnotationStore`)。
- 归一化坐标 + 双路径统一渲染(`AnnotationRenderer.draw`,预览与导出同一函数)——**这是缩放和形状能便宜地加进来的根本原因**。

### 1.2 差距清单(按对用户的影响排序)

| # | 差距 | 影响 |
|---|---|---|
| 1 | 编辑画布永远整图适配窗口(`MarkupCanvas.fittedRect`),不能缩放平移 | 高分辨率照片上给局部打码/描点做不了;马赛克档位 3.5%–10% 宽度在整图视野下只能粗描。**最大硬伤** |
| 2 | 没有形状工具(矩形/椭圆/直线/箭头) | 预览标记的核心能力;圈重点、指位置的高频操作目前只能用画笔手涂 |
| 3 | 顶栏右侧「覆盖原图(红)/退出/导出…」三按钮常驻 + 水印是孤立齿轮 | 破坏性动作与普通动作并排,视觉噪音大;水印只在导出生效却放在编辑工具区,认知错位 |
| 4 | 「拉直」按钮常驻(属于裁切变换,文字工具下无意义) | 工具条状态与当前工具不匹配 |
| 5 | 文字只有 小/中/大 三档字号 | 预览是文本框 + 角柄连续缩放;三档在真实排版里经常不合适 |
| 6 | 没有荧光笔(半透明粗笔) | 批注截图常用,成本极低 |

### 1.3 与预览.app 的交互对照

| 预览.app | 现状 | 处理 |
|---|---|---|
| 编辑时可任意缩放/滚动 | 固定适配 | **B1** |
| 矩形/椭圆/直线/箭头形状工具 | 无 | **B2** |
| 破坏性操作不占工具栏 | 覆盖原图红字常驻 | **B3** |
| 文本框角柄拖拽改字号 | 三档 | **B4** |
| 荧光笔 | 无 | **B4** |
| 图层列表 / 多选 / 自由旋转文字 | 无 | 预览也没有(或极浅),**明确不做** |

---

## 2. 结论与顺序

| 期 | 功能 | 建议版本 | 预估 | 依赖 | 可裁剪 |
|---|---|---|---|---|---|
| ~~**B0**~~ | 现有功能打磨(§10) | ✅ 0.5.26–0.5.36 已落地 | — | 无 | — |
| **B1** | 编辑画布缩放平移(§3) | 0.6.0 | 1–1.5d | 无 | 否(后续精修的底座) |
| **B2** | 形状工具(矩形/椭圆/直线/箭头)(§4) | 0.6.1 | 1–1.5d | 无(B1 可并行) | 否 |
| **B3** | 顶栏收敛:导出分裂菜单、水印入导出流(§5) | 0.6.2 | 0.5d | 无 | 否 |
| **B4** | 文字角柄连续字号 + 荧光笔(§6) | 0.6.3 | 1d | B1(角柄在缩放视口里拖) | 自定义颜色(§6.3)可砍 |

硬顺序:**B1 → B2 → B3 → B4**(B2/B3 理论可提前,但 B1 是底座先做收益最大;B4 依赖 B1 的视口数学)。版本号是**建议值,以用户最终决定为准**;每期结束跑 §8 门禁。

---

## 3. B1 编辑画布缩放平移

### 3.1 设计决策(冻结)

- **不引入 NSScrollView**。整个缩放只改 `MarkupCanvas.fittedRect` 的返回值:把「适配矩形」按 zoom 放大、按 pan 平移,得到 `viewRect`。图片、覆盖层、选区描边、实时笔迹、草稿字号**全部从 `fit` 派生**,改一个矩形,整层自动跟随,指针 → 归一化坐标的 `normalized(_:fit:)` 换算天然正确。不用 `scaleEffect`(那会缩放命中层和 TextField 的字体度量,引发一串边角问题)。
- 缩放范围:**1×(适应窗口)– 8×**。基线预览图是 1500px,超过约 2–3× 就开始糊,8× 是给马赛克定位用的上限,允许糊(预览.app 放大同样糊,导出走原图无损)。
- 手势(对标预览.app):
  - 双指捏合(`magnify(with:)`)= 以指针为锚缩放;
  - ⌘+滚轮 = 以指针为锚缩放;
  - 滚轮 / 触控板双指滑动 = 平移;
  - 按住空格拖拽 = 平移(鼠标用户的兜底);
  - `⌘0` = 适应窗口复位;画布右下角小胶囊显示当前倍率,含 `−` / `适应` / `+` 三个点击区(只在标记类工具下显示,裁切工具不显示)。
- **裁切画布不缩放**(保持整图适配,scope 边界)。切到裁切时隐藏倍率胶囊;缩放状态保留,切回标记工具恢复。
- 平移夹取规则:图任一边 ≤ 容器时该方向居中;图大于容器时该方向偏移限制在 `[容器 − 图, 0]`,不允许把图完全拖出视野。

### 3.2 纯函数(必须单测,放 `Models/` 或 `Services/`)

```swift
enum EditCanvasMath {
    /// 由容器、图像宽高比、倍率、平移算出图像在画布上的显示矩形(全部坐标准则同现有 fittedRect)。
    static func viewRect(container: CGSize, imageAspect: CGFloat,
                         zoom: CGFloat, pan: CGSize) -> CGRect
    /// 以 anchor(容器坐标)为锚放大 factor 倍后的 zoom/pan;内部做 1...8 夹取 + 平移夹取。
    static func zoomed(zoom: CGFloat, pan: CGSize, factor: CGFloat,
                       anchor: CGPoint, container: CGSize, imageAspect: CGFloat) -> (zoom: CGFloat, pan: CGSize)
    /// pan 平移 delta 后的合法 pan(夹取规则见 3.1)。
    static func panned(pan: CGSize, delta: CGSize, container: CGSize, imageAspect: CGFloat, zoom: CGFloat) -> CGSize
}
```

测试点:锚点不动性(缩放前后 anchor 下的归一化点不变)、夹取边界(zoom<1 / >8、图小于容器居中、图大于容器不脱出)、倍率为 1 时 pan 恒归零。

### 3.3 实现要点

- `CanvasMouseCatcher`(在 `CropView.swift`)增加 `onScroll`/`onMagnify` 回调:覆盖 `scrollWheel(with:)`(区分 `event.modifierFlags.contains(.command)`)与 `magnify(with:)`(`event.magnification` 累计);空格平移用 `flagsChanged` 跟踪空格按下态,按下时 `mouseDown` 走平移而非绘制(工具回调前置判断)。
- zoom/pan 状态放 `EditView` 的 `@State`(裁切工具切换时不销毁);`MarkupCanvas` 改为接收 `zoom/pan` 或直接接收算好的 `viewRect`。
- 窗口 resize 时用现 `viewRect` 重算等价 pan(保持视野中心不动)——`viewRect` 纯函数可直接反解。
- 性能:缩放只是改变显示矩形,底图/覆盖层仍是同一张 1500px `NSImage`,`interpolation(.high)` 已有;不做逐级解码(导出不受影响)。
- **坑(项目实证)**:`NSViewRepresentable` 无固有尺寸必须显式给 frame;事件监听器生命周期跟随宿主视图(`viewDidMoveToWindow` 挂/`deinit` 拆);`cursorUpdate` 里禁调 `invalidateCursorRects`(v0.5.26 闪退)。

### 3.4 B1 任务清单(按序执行)

1. 新建 `Sources/Pictool/Models/EditCanvasMath.swift`:`viewRect(container:imageAspect:zoom:pan:)` / `zoomed(zoom:pan:factor:anchor:container:imageAspect:)` / `panned(pan:delta:container:imageAspect:zoom:)`。夹取规则:zoom ∈ 1...8;pan:某边 ≤ 容器 → 该方向居中,> 容器 → 偏移限 `[容器−图, 0]`;zoom == 1 时 pan 归零。纯函数,不 import SwiftUI(只 CoreGraphics)。
2. 单测 `EditCanvasMathTests`:①zoom=1 输出与原 `fittedRect` 一致;②锚点不动性(zoomed 前后 anchor 下归一化点不变);③zoom 下限/上限夹取;④图小于容器居中、大于容器不脱出;⑤resize 视野中心不动(等价 pan 反解)。
3. `EditView` 增 `@State editZoom: CGFloat = 1` / `editPan: CGSize = .zero`;`MarkupCanvas` 增 `zoom`/`pan` props,`fittedRect` 改为调 `EditCanvasMath.viewRect`(行为向后兼容)。
4. `CanvasMouseCatcher` 扩展:`onScroll(dx:dy:commandHeld:)`、`onMagnify(factor:anchor:)`、空格跟踪(`flagsChanged`,keyCode 49)→ 按住空格时 mouseDown/drag 改走 `onPanStart`/`onPan(translation:)` 且抑制绘制类回调;滚轮非精确 delta 乘系数 ~4(普通鼠标一格 ≈ 40pt)。
5. `EditView` 接线:⌘滚轮/捏合 → `zoomed`(锚点=指针容器坐标);滚轮/触控板滑动 → `panned`;空格拖 → `panned`;`hiddenShortcuts` 加 `⌘0`(复位 fit)/`⌘=`/`⌘-`(×1.25 步进,锚点=视口中心)。
6. 倍率胶囊:画布右下角 overlay(仅 `tool != .crop`),显示 `Int(editZoom*100)%`,含 `−`/`适应`/`+` 三个可点区;`.help` 标注快捷键。
7. 容器 resize:`GeometryReader.onChange(of: geo.size)` → 视野中心不动重算 pan。
8. 手工验收:捏合/⌘滚轮锚点正确、滚轮平移、空格拖拽、⌘0 复位、胶囊三键、裁切工具下隐藏且返回后恢复、zoom>1 下画笔/马赛克/文字草稿位置与字号正确、撤销重做不受缩放影响。

---

## 4. B2 形状工具(矩形 / 椭圆 / 直线 / 箭头)

### 4.1 模型(改 `MarkupAnnotation.swift`)

```swift
enum ShapeKind: String, CaseIterable, Sendable { case rect, ellipse, line, arrow }

case shape(kind: ShapeKind, from: CGPoint, to: CGPoint, widthLevel: Int, colorIndex: Int)
```

- `rect`/`ellipse`:`from`/`to` 为对角点(绘制时 `standardize` 成正矩形);`line`/`arrow`:两端点。全部归一化。
- 形状**只描边不填充**;线宽复用 `strokeWidths` 表;颜色复用调色盘。虚线/填充/圆角明确不做。

### 4.2 工具条

- `EditTool` 增 `case shape`(图标 `square.dashed` 或 `plus.rectangle.on.rectangle`——选系统里语义最近的,文案「形状」)。
- 属性区在 `tool == .shape` 时显示**形状 chip**(当前形状名 + chevron,弹层四选一),与马赛克的效果 chip 同构;颜色/大小 chip 照常出现。

### 4.3 渲染(`AnnotationRenderer`)

- rect:`ctx.stroke(rect)`;ellipse:`ctx.stroke(ellipse(in: rect))`;line:两端点线段;arrow:线段 + **实心三角头**,头长 = `max(3×线宽, 2%画幅短边)`(避免细线时箭头不可见),头方向沿线段方向。
- `AnnotationRenderer.draw` 的外层翻转到显示坐标逻辑照旧;形状绘制在翻转后坐标做即可。

### 4.4 命中 / 选区 / 交互

- 命中:rect/ellipse 用 bounds 包含(无填充也按内部命中,便于移动);line/arrow 用**点到线段距离 ≤ 容差**(复用 `MarkupGeometry.distance` 逻辑)。命中测试抽纯函数 + 单测。
- 选区 bounds:`standardize` 后的矩形外扩线宽的一半(箭头要包含头)。
- 移动/删除/方向键微调/颜色大小联动:全部走现有选中标注基建,**不需要新逻辑**。
- 绘制手势:`handleDragStart` 空 hit 时记 `from`,拖动中更新 `to`(实时预览直接在 overlay 重绘管线里走,马赛克已验证这条路的刷新成本可接受),抬起提交 + 入撤销栈。

### 4.5 纯函数 API(单测)

```swift
extension MarkupGeometry {
    static func shapeBounds(kind: ShapeKind, from: CGPoint, to: CGPoint,
                            widthFraction: CGFloat) -> CGRect
    static func hitShape(kind: ShapeKind, from: CGPoint, to: CGPoint,
                         tolerance: CGFloat, at point: CGPoint) -> Bool
    static func arrowHead(from: CGPoint, to: CGPoint, widthFraction: CGFloat) -> (tip: CGPoint, base: (CGPoint, CGPoint))
}
```

### 4.6 B2 任务清单(按序执行)

1. `MarkupAnnotation.swift`:`enum ShapeKind: String, CaseIterable, Sendable { case rect, ellipse, line, arrow }`;`Annotation.Kind` 增 `.shape(kind:from:to:widthLevel:colorIndex:)`(from/to 归一化);`MarkupGeometry` 增纯函数:`standardizedRect(from:to:)`(负宽高翻转)、`shapeBounds`(含线宽外扩,箭头含头)、`hitShape`(rect/ellipse 按 bounds 内含,线/箭头按点到线段距离 ≤ 容差,容差公式同 `stroke(contains:)`)、`arrowHead`(头长 = max(3×线宽, 2% 画幅短边),返回尖端与两底点)。
2. 单测:standardizedRect 负宽高;shapeBounds 三类形状与外扩;hitShape 命中/未命中/容差边界(线段容差参照 `testStrokeContainsWithTolerance`);arrowHead 方向(垂直线/水平线/斜线)与长度下限。
3. `EditTool` 增 `.case shape`(`systemImage: "rectangle.dashed"`,label「形状」;`levelLabel` 归入「粗细」分支)。B0 的 `switchTool`/`hiddenShortcuts` 不用改(属性 chip 自动跟随)。
4. `EditView` 增 `@State shapeKind: ShapeKind = .rect` + `@State liveShapeTo: CGPoint?`;attributeCluster 在 `tool == .shape` 时显示形状 chip(弹层四选一,样式仿 `mosaicMenu`,选中打勾)。
5. 手势:`handleDragStart`(.shape,无命中)记 `dragStartPoint` 起点并在 `liveShapeTo = point`;`handleDragChange` 更新 `liveShapeTo`;`MarkupCanvas` 增 `liveShape` 相关 props,实时预览用 SwiftUI `Path` 直接描(不进 overlay 重绘管线);`handleDragEnd` 提交 `.shape` 标注(pushUndo + 选中),`liveShapeTo = nil`。
6. `AnnotationRenderer.draw` 增 `.shape` 分支:rect/ellipse 描边、line 线段、arrow 线段 + 实心三角头(`arrowHead` 纯函数供几何);线宽/颜色/描边色规则沿用画笔(浅色近黑描边)。
7. 全量接线(编译器 switch 穷尽性兜底,逐一核对):`EditView` 的 `hitTest`(kinds 含 `.shape`)、`kindOf`、`moveSelected`(from/to 平移,复用 clampedTranslate 思路)、`nudge`、`syncControlsFromSelection`、`applySizeLevelToSelection`、`applyColorToSelection`;`MarkupCanvas.selectionBounds`;右键菜单与 hoverTest 的 kinds 数组;橡皮 `erase(at:)` 的 kinds。
8. 验收:四种形状创建/实时预览/选中/移动/微调/改色改粗/删除/撤销重做;导出文件与画布预览逐形状一致;缩放(B1)下创建位置准确。

### 4.7 B2 明确不做

填充、虚线、圆角、手柄重塑(创建后只能移动/删)。

---

## 5. B3 顶栏收敛与导出流

1. **导出改分裂菜单**(SwiftUI `Menu` + `primaryAction`,macOS 14 支持):点主按钮 = 「存储为…」(走现有 ExportOptionsForm popover 流程);长按/下拉菜单项:「存储为…」「覆盖原图」(仅 `overwriteFormat != nil` 时出现,`role: .destructive`)。
2. **顶栏删掉常驻红色「覆盖原图」按钮**——破坏性动作收进导出菜单。
3. **水印入口挪进导出弹层**:ExportOptionsForm 增「水印」开关行 +「设置…」按钮(弹现有 `WatermarkSettingsForm` popover);顶栏齿轮删除。理由:水印只在导出时烙印,编辑期完全不可见,入口放导出流才符合认知(与 CropView 的导出面板一致)。
4. **「拉直」只在裁切工具下显示**(rotate/flip 保留常驻——它们对标记场景也有意义)。
5. 顶栏右侧最终形态:`[工具区 | 属性区 | 变换区 | 撤销重做 | 弹性空隙 | 退出 | 导出分裂菜单]`。

### 5.1 B3 任务清单(按序执行)

1. 顶栏「导出…」按钮改 `Menu`:`primaryAction: { showExportPopover = true }`(沿用现 popover 流程);菜单项:「存储为…」(同 primary)、「覆盖原图」(仅 `overwriteFormat != nil`,`role: .destructive`,直调 `export(overwrite: true)`,help 标注「原像素不可恢复」);删除独立红色「覆盖原图」按钮。
2. `ExportOptionsForm` 增「水印」行:`Toggle("水印", isOn: $watermarkDraft.enabled)` + 「设置…」按钮(`showWatermarkSettings` popover 弹现有 `WatermarkSettingsForm`);bindings 由 EditView 传入。
3. 顶栏水印齿轮按钮及 `showWatermarkSettings` 顶栏 popover 删除(状态保留,供导出弹层用)。
4. `hiddenShortcuts`/导出键盘默认键(⌘⏎ defaultAction)核对不回归。
5. 验收:存储为(面板路径)、覆盖原图(确认弹窗 + 原子替换)两条路径;水印开关/设置在导出弹层内实时改画布预览;无水印时导出无烙印;顶栏无齿轮且无红色文字按钮。

---

## 6. B4 文字连续字号 + 荧光笔

### 6.1 文字角柄(依赖 B1)

- `Annotation.Kind.text` 的 `sizeLevel: Int` 改为 `sizeFraction: CGFloat`(内存模型直接改,无迁移负担);默认值取现表 `0.030 / 0.048 / 0.070` 之一。`MarkPalette.textSizes` 保留为**预设档**,chip 点击即设 fraction。
- 选区描边的右下角加**方形手柄**(约 8pt,随 zoom 保持屏幕恒定尺寸——用容器坐标画,不吃 `fit` 缩放);拖动手柄改 fraction,夹取 `[0.015, 0.120]`,手势开始时入撤销组(复用 `beginUndoGroup`)。
- 命中优先级:**手柄 > 标注体 > 空白**。`textHitRect` 改用 fraction(渲染器 `textSize(content:sizeFraction:)` 已是 fraction 接口,风险低)。
- 宽高比锁定:拖角柄只改字号(以文字锚点为基准等比缩放),不支持拉伸变形——明确不做自由变形。

### 6.2 荧光笔

- `EditTool` 增 `case highlighter`(图标 `highlighter`,文案「荧光笔」)。
- `Annotation.Kind.stroke` 增参 `style: StrokeStyleKind = .solid`,`enum StrokeStyleKind { case solid, highlighter }`;渲染时 highlighter 用 `alpha 0.45` + 专属宽度表 `[0.012, 0.020, 0.032]` + 圆帽。同色两笔叠加**不加深**(半透明叠加天然加深,预览.app 也如此,接受)。
- 命中/移动/删除/微调与画笔完全共用;橡皮同样可擦。

### 6.3 可选:自定义颜色(工期紧可砍)

- 颜色弹层底部加 `NSColorWell`(包 `NSViewRepresentable`);选中自定义色时标注存 **RGB 而非 colorIndex**——`Kind` 各 case 的 `colorIndex: Int` 改为 `color: MarkupColor`:

```swift
enum MarkupColor: Sendable { case palette(Int), custom(r: Double, g: Double, b: Double) }
```

- 渲染器/命中/选区同步。若做,必须先落 B2/B3/B4 其余项再动(改 `Kind` 签名会波及全部工具)。

### 6.4 B4 任务清单(按序执行)

1. **文字连续字号**:`Annotation.Kind.text` 的 `sizeLevel: Int` → `sizeFraction: CGFloat`(内存模型直接改;默认 0.048);`MarkPalette.textSizes` 保留为三档预设,chip 点击 = 设 fraction 为表值;`textHitRect` 改收 fraction(`AnnotationRenderer.textSize` 已是 fraction 接口);`syncControlsFromSelection` 把 fraction 反映射为最近档用于 chip 高亮。
2. 单测:`textHitRect` fraction 版边界(最小 0.02 兜底、不把像素当归一化);fraction 夹取 `[0.015, 0.120]` 的工具函数(放 `MarkPalette.clampTextFraction`)。
3. **角柄**:`MarkupCanvas.selectionOutline` 增右下角方形手柄(容器坐标约 8pt,白底黑边,不随 zoom 缩放);`handleDragStart` 前置手柄命中判断(命中容差 = 10pt 折算归一化);拖动中 `newFraction = clamp(起始fraction × 当前对角距/起始对角距)`,锚点=文字块左上;手势首动 `pushUndo`(一次手势一条撤销);`handleDragChange/End` 里手柄命中态优先于移动。
4. **荧光笔**:`EditTool` 增 `.highlighter`(`systemImage: "highlighter"`,label「荧光笔」);`Annotation.Kind.stroke` 增 `style: StrokeStyleKind = .solid`(`enum StrokeStyleKind: String { case solid, highlighter }`);`MarkPalette.highlighterWidths = [0.012, 0.020, 0.032]`;`AnnotationRenderer` 画 highlighter 时 alpha 0.45 + round cap;`levelLabel`/`sizeMenu` 按 style 切宽度表(选中的荧光笔迹同理);`kindOf(.stroke)` 返回 `.brush` 不变,橡皮/移动/微调/右键全兼容。
5. 验收:角柄拖拽改字号(含 zoom>1 下)、三档 chip 与 fraction 联动、撤销一条手势一步、荧光笔半透明叠色与预览/导出一致、橡皮可整笔擦除荧光笔。

---

## 7. 明确不做(全期)

- 裁切画布缩放(裁切保持整图适配)。
- 图层列表、多选批量操作、标注层级调序。
- 文字字体族/对齐/描边样式;文字自由变形(拖拽只改字号)。
- 形状填充、虚线、圆角、阴影;形状手柄重塑(创建后只能移动/删,重塑列后续 C 期)。
- 缩放逐级重解码高清原图(基线 1500px 够用;导出永远走原图)。
- 标注持久化到磁盘(会话级即可,现状已是)。

---

## 8. 每期门禁(与 MARKUP_PLAN 第 11 节一致)

- `swift build` 0 error;`swift test` 全绿(新增纯函数必须有单测)。
- 手工自测:见各期「实现要点」里的交互项(缩放锚点、夹取、手柄命中优先级)。
- 版本号同步(`build.sh`)+ `README.md`「版本」小节一行 + `./build.sh` 打包。
- UI 文案中文;`.help` 提示补齐快捷键(如「适应窗口 (⌘0)」)。

## 9. 代码锚点(避免搜错)

| 路径 | 相关点 |
|---|---|
| `Sources/Pictool/Views/EditView.swift` | `EditView`(状态机/交互回调/导出)、`MarkupCanvas`(fittedRect/指针换算/草稿)、`ExportOptionsForm` |
| `Sources/Pictool/Views/CropView.swift` | `CanvasMouseCatcher`(要加 scroll/magnify/space)、`CropCanvas`(裁切画布,B1 不动) |
| `Sources/Pictool/Models/MarkupAnnotation.swift` | `Annotation.Kind` / `EditTool` / `MarkPalette` / `MarkupGeometry` |
| `Sources/Pictool/Services/AnnotationRenderer.swift` | 双路径统一绘制(B2/B4 只动这里和模型) |
| `Sources/Pictool/Models/AnnotationStore.swift` | 会话级缓存,已有,不动 |
| `Tests/PictoolTests/PictoolTests.swift` | 现有 78 项;新增 `EditCanvasMathTests` / 形状几何测试 |

---

## 10. B0 现有功能交互打磨(2026-09-05 评估,**已落地 v0.5.26**)

> 只动已有行为,不加新工具。P0 是读代码确认的功能缺陷,不只是打磨。
> 全部改动不触碰 `MARKUP_PLAN.md` 的冻结约定(渲染双路径/归一化坐标/调色盘表不变)。

### 10.1 P0 — 功能缺陷(必修)

**B0-1 画笔/马赛克笔迹无法拖动移动。**
`handleDragChange` 只实现了 `.text` 的移动(`moveSelected` 也只处理 text case);笔迹命中后 `selectingExisting = true` 直接 return——用户点选一笔后拖不动,和文字行为不一致。
方案:`moveSelected` 三 kind 全支持。stroke/mosaic 记 `dragStartPoint`,增量 `delta = current - dragStart`,点数组逐点平移;undo 沿用 `pushUndoForMoveIfFirst`(一次手势一条撤销)。纯函数:

```swift
extension MarkupGeometry {
    static func translated(points: [CGPoint], dx: CGFloat, dy: CGFloat) -> [CGPoint]
    /// 平移后把点夹回 [0,1](任一点越界则整笔夹住),防止笔画被拖出画布外
    static func clampedTranslate(points: [CGPoint], dx: CGFloat, dy: CGFloat) -> [CGPoint]
}
```

单测:平移不变性(长度)、整笔夹取(一笔部分出界时整笔不拆)。

**B0-2 选中标注方向键微调缺失。**
`nudge(dx:dy:)` 首行 `guard tool == .crop`——方向键在标记工具下是空操作,隐藏快捷键(§EditView hiddenShortcuts)白挂。选中标注后按方向键毫无反应。
方案:`nudge` 分流——tool == .crop 保持现状;否则 selectedID 非空时平移该标注(步长 0.002,Shift 0.008,单点类同笔迹用 clampedTranslate,文字用 `moved` 后夹 0…1)。与 B0-1 共用纯函数与 undo 策略(连按合并为一次手势的 undo?**不合并**,每次按键一条撤销,与裁切微调行为一致)。

**B0-3 文字草稿中输入 c/d 会触发「裁切…」「标记…」菜单。**
菜单里这两项**编辑态刻意保持可用**(`PictoolApp.swift:137,140` 的 `isModalPresented && !isEditing` 放行),裸键等价键在 TextField 聚焦时仍被菜单拦截——草稿里打不出字母 c/d,反而切走工具。
方案:`FolderStore` 增 `isTextDraftActive`(EditView `onChange(of: draftFocused)` 同步,onDisappear 复位);两个菜单项的 disabled 条件追加 `|| store.isTextDraftActive`。**B0-8 的工具单键快捷键将来必须走同一个门禁**。

### 10.2 P1 — 交互一致性与性能

**B0-4 画布无光标反馈。** 全程箭头,感知不到工具差异与可拖拽性。
方案:`CanvasMouseCatcher` 用 `resetCursorRects()`(加 `trackingArea` 做 hover 命中):文字工具 I 型;画笔/马赛克/橡皮十字;悬停在可选对象上 pointingHand(命中节流,mouseMoved 里限频)。
**as-built 坑(v0.5.26→v0.5.27 闪退)**:`cursorUpdate(with:)` 是 AppKit 显示周期光标更新阶段调进来的,在里面调 `window.invalidateCursorRects` 会重入 `_updateStructuralRegionsOnNextDisplayCycle` 抛 NSException 直接崩。悬停光标刷新只能由 `mouseMoved`/`mouseExited` 驱动,tracking area 不要挂 `.cursorUpdate`。

**B0-5 裁切弹层与顶栏控件重复。** 顶栏已有旋转×2/翻转×2,`cropMenu` 弹层里再来同样四个图标;「覆盖原图」同时出现在顶栏红字与弹层底部。
方案:弹层删掉四个变换图标与覆盖原图(顶栏是唯一入口);弹层只留 拉直滑杆 + 比例/尺寸区。(B3 的导出菜单会再收走顶栏红字,两期衔接不冲突。)

**B0-6 马赛克实时重绘无节流。** `onChange(of: livePoints)` 每个采集点都触发一次全幅 overlay 后台重绘(1500px 位图 + NSImage 包装),快速长笔画时重绘排队,generation 丢弃旧帧但 CPU 白烧。
方案:时间门槛节流(≥30ms 才 rebuildOverlay;松手时强制补一帧)。纯 UI 行为,不需单测。

**B0-7 选中标注无上下文操作入口。** 只有隐性的 Del 键和双击(文字);右键无菜单。
方案:画布右键菜单——命中标注时:编辑(仅文字)/删除;空白时:无菜单。与预览.app 的右键语义对齐。

### 10.3 P2 — 可选打磨(工期紧可砍)

**B0-8 工具单键快捷键**(T 文字 / B 画笔 / M 马赛克 / E 橡皮 / C 裁切,加入 hiddenShortcuts,**必须**挂 `isTextDraftActive` + `editingCustomRatio` 门禁,与 B0-3 同一门禁)。
**B0-9 工具切换保留选中**(预览.app 切工具不清选中;换工具后属性 chip 按新工具语义继续作用于该选中——注意 mosaic 的效果 chip 只对马赛克标注生效,需按 kind 过滤)。
**B0-10 选中描边可读性**:浅色背景上 1pt 虚线看不清,给选区描边加细白描边双层(stroke 深色 + 内层白色)或投影。

### 10.4 B0 明确不做

- 缩放平移(B1)、形状(B2)、导出菜单重构(B3)、文字角柄(B4)。
- 撤销栈结构改造、标注持久化、逐级高清解码。
- 橡皮改局部擦除(保持整对象删除,与预览一致)。
