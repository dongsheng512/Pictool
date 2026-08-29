# Pictool UI / 交互审查报告

审查范围:`Sources/Pictool` 全部 20 个 Swift 文件(约 4700 行)。
方法:通读 + 对可疑逻辑写最小复现脚本实测(结论标注了「实测」的都是跑出来的,不是推断)。

---

## 结论速览

| 级别 | 数量 | 说明 |
|---|---|---|
| P0 功能性 Bug | 3 | 已实测确认,会导致错误结果或明显画质问题 |
| P1 缺陷 / 性能 | 8 | 高概率失效、资源泄漏或可感知卡顿 |
| P2 交互优化 | 12 | 体验打磨点 |

## 修复进度(2026-08-28 第二遍)

已按本报告实施修复,全部 3 个 P0、8 个 P1、以及 8 项 P2 已落地:

| 项 | 处理 |
|---|---|
| P0-1 裁切 EXIF 方向错位 | ✅ `facts()` 按 orientation 对调;新增 4 项端到端单测(造真 JPEG 验证裁切像素) |
| P0-2 比例锁定边手柄跳转 | ✅ 数学抽成 `CropMath.ratioLockedRect` 纯函数,显式 min/max/center 锚点;8 项单测 |
| P0-3 100% 缩放不加载原图 | ✅ 升级基准改用位图真实像素、阈值 0.9;另修「实际大小」以位图尺寸算 scale 导致只到 70% |
| P1-1 ~ P1-8 | ✅ 全部修复(顶栏手势层、动图升级、重绘去重、continuation 泄漏、扫盘、转圈、裸键、删除确认) |
| P2 | ✅ 已做 8 项:拖放高亮、画布右键菜单、裁切手柄热区与描边、缩放预设档位、原始比例、全选、旋转提示、窗口位置记忆 |

**仍未处理(需要 UI 实机验证,风险较高)**:

- P2 滑动切图无跟手反馈(需改 `CanvasImageView` 拖拽渲染,肉眼调参)
- `FolderStore.revealExternalImages` 里 `ImageDiscovery.images(in:)` 仍在主线程全量扫盘
  (函数有 4 个分支依赖扫描结果,异步化属于结构改动,建议单独一轮)
- P2 纯净模式 hover HUD、打印全尺寸解码的超时/取消

验证情况:`swift build` / `-c release` 均通过,单测 55 项全绿(新增 13 项)。
App 启动冒烟在本机 shell 里做不了——无 WindowServer,改动前后都立即退出,已用 worktree 对照确认与改动无关。

---

## P0 — 已确认的功能性 Bug

### P0-1 裁切:EXIF 方向 ≠ 1 的照片,裁切结果完全错位【实测】

**涉及**:`CropView.loadPreview()` / `CropService.encode()` / `ImageLoader.facts()`

`ImageLoader.facts()` 读的是 `kCGImagePropertyPixelWidth/Height`,即**文件里存储的原始尺寸**;
而 `makeCGImage()` 用了 `kCGImageSourceCreateThumbnailWithTransform: true`,返回的 CGImage 是**已按 EXIF 方向摆正后的位图**。
两者在 orientation ≠ 1 时宽高对调,Crop 链路却把前者当成了后者的坐标系。

实测(生成一张 40×20、orientation=6 的 JPEG):

```
facts() 报告像素尺寸 (CropView 用的 pixelSize): 40 x 20
实际解码位图 (预览 NSImage 尺寸):               20 x 40
```

后果分两处:

1. **`CropView`**:`imageAspect = pixelSize.w / pixelSize.h` 按**未摆正**的比例排版画布,
   而 `preview` 是**已摆正**的 NSImage。竖拍照片会被塞进一个横向框里信箱化显示,
   选区叠加层的坐标基准和眼睛看到的图对不上——框哪儿不裁哪儿。
2. **`CropService.encode()`**:`CropMath.pixelRect(pixelSize:)` 按 4032×3024 算出裁剪矩形,
   却拿去 `cropping(to:)` 一张 3024×4032 的 CGImage。裁出来的是错的区域。

**影响面**:几乎所有 iPhone 竖拍照片(orientation = 6),以及相当比例的相机 RAW。
`ImageViewCanvas` 不受影响——它全程用 `image.size`(已摆正),`facts` 只用于状态栏文字。

**修法**:让 `facts()` 同时返回 orientation;当 orientation 为 5/6/7/8 时,
把 `pixelWidth/pixelHeight` 对调后再交给 Crop 链路。改动收口在 `ImageLoader.SourceFacts` 一处,
单测可覆盖(目前 14 项单测没有一条覆盖 orientation ≠ 1)。

---

### P0-2 裁切:锁定比例后拖「边」手柄,选区横向/纵向跳半个身位【实测】

**涉及**:`CropCanvas.apply(kind:base:dx:dy:minNorm:)` 第 350-369 行

比例约束里,边手柄(.top/.bottom/.left/.right)在**垂直轴**上取的是 `rect.midX` / `rect.midY` 作为锚点,
但最后一行 `anchorX + (anchorX == base.minX ? 0 : -width)` 是**按「边对齐」写的**,
没有处理「锚点是中心」这种情况——中心锚点被当成了右/下边缘。

实测(基准选区 `0.2,0.2,0.6,0.4`,锁定 1:1):

```
基准选区中心 = (0.500, 0.400)
拖 top     手柄 → 水平中心 0.500 → 0.275 (偏移 -0.225)   ← 正好是 width/2
拖 bottom  手柄 → 水平中心 0.500 → 0.275 (偏移 -0.225)
拖 left    手柄 → 垂直中心 0.400 → 0.200 (偏移 -0.200)   ← 正好是 height/2
拖 right   手柄 → 垂直中心 0.400 → 0.200 (偏移 -0.200)

对照:拖 topLeft     → (0.35, 0.15, 0.45, 0.45)  对角固定,正确
     拖 bottomRight → (0.20, 0.20, 0.45, 0.45)  对角固定,正确
```

四个角手柄是对的,四条边全部错。用户拖上边缘时,选框会**突然向左弹半格**,之后每帧都在和夹取逻辑打架(16:9 这类宽比例下甚至会一路滑到 x=0)。

**修法**:把锚点语义显式化。边手柄在垂直轴上应该锚中心:

```swift
let x = switch anchorXKind {
    case .min:  anchorX                    // 左边固定
    case .max:  anchorX - width            // 右边固定
    case .mid:  anchorX - width / 2        // 中心固定 ← 缺的就是这一支
}
```

---

### P0-3 主视图:缩放到 100% 仍显示降采样图,「实际大小」是插值画质

**涉及**:`ImageViewCanvas.Coordinator.setDisplayImage()` 与 `maybeEscalate()`

`setDisplayImage` 里 `bitmapPixelSize = truePixelSize`,把**当前位图像素**记成了**源图像素**。
`maybeEscalate()` 又拿 `bitmapPixelSize` 当升级判定的基准:

```swift
let displayedPx = imageView.frame.width * backing
if displayedPx > bitmapPixelSize.width * 1.05 { escalate {} }
```

算式举例:4000px 宽的图,窗口 1400pt,2x 屏。

- `displayMaxPixel()` = max(2048, 1400×2) = **2800** → 浏览位图实际是 2800px 宽
- 用户 ⌘+滚轮放大到 100%:`frame.width = 2000pt`,`displayedPx = 4000`
- 判定:`4000 > 4000 × 1.05 = 4200` → **false,不升级**

结果:2800px 的位图被拉伸到 4000 设备像素显示——**「实际大小」看到的是插值,不是原图**。
必须再放大到 105% 以上才触发升级。

注意 `performZoom(.actualSize)`(按「1」)是**先 escalate 再缩放**的,所以走按钮没事;
但**偏好设置里选「打开时缩放 = 实际大小」**走的是 `applyActualSizeImmediate()` →
`scheduleEscalateCheck()` → `maybeEscalate()`,同样不触发。**这条路线上新开的每一张图都是软的。**

**修法**:`maybeEscalate()` 的 guard 里已经取到了正确的值:

```swift
let rep = image.representations.first, rep.pixelsWide > 0
```

把判定基准从 `bitmapPixelSize.width` 换成 `rep.pixelsWide`(当前位图真实像素),
并把阈值从 `× 1.05` 降到 `× 0.9`,让全尺寸在到达 100% 之前就位。
`bitmapPixelSize` 继续留给 `effectiveScale()` 做百分比读数(那里的语义是对的,不用动)。

---

## P1 — 高概率缺陷与性能问题

### P1-1 顶栏的「拖动窗口 / 双击缩放」层被不透明背景压住了

`PureHeader` 连着挂了两个 `.background`。SwiftUI 里后挂的在**更底层**,
所以承载手势的 `Color.clear` 层被前面不透明的 `MainChromeBackground` 完全遮住,大概率收不到事件。

- **拖动窗口**目前无感——`ChromeView.stripTitlebar()` 设了 `isMovableByWindowBackground = true`,整窗可拖,把这个 bug 盖住了。
- **双击顶栏空白处缩放窗口**基本可以确定是失效的。

**修法**:两层合并成一个 `.background`,或者把手势层改成 `.overlay`(但要给按钮留出让位)。

### P1-2 动图遇到缩放,会白跑一次全尺寸解码

`stopAnimation()` 只在 `applyFile` 和 `performRotate` 里调,`escalate()` 不调。
一张 480px 的 GIF 在大窗口里 fit 显示时,`displayedPx` 立刻超过阈值 → 触发全尺寸解码 →
`imageView.image = full`,**下一帧动画回调马上又把它换成 480px 的帧**。

后果:白解一张大图、闪一帧静态图、`isFullResolution` 变成谎言。按「1」看动图时必现
(`performZoom(.actualSize)` 无条件 escalate)。

**修法**:`maybeEscalate()` 和 `escalate()` 入口加 `frameCount == 1` 的守卫;动图本来就没有更高分辨率可升。

### P1-3 `updateNSView` 每次都强制画布重绘

```swift
clipView.canvasBackground = background   // didSet { needsDisplay = true }
```

`CanvasClipView.canvasBackground` 的 didSet 无条件置脏。而 `updateNSView` 在**每次 SwiftUI 重渲染**都会跑。
缩放时 `notifyScale()` → `store.displayScale` → body 重渲染 → `updateNSView` → 整块画布重绘。
平滑缩放是 60-120fps,等于每帧全画布刷一次底色。

**修法**:`applyBackground` 里先判等;didSet 里也判等。

### P1-4 `cancelAll()` 泄漏挂起的 continuation

`ThumbnailProvider.cancelAll()` 和 `DisplayImageCache.cancelAll()` 都是
`inFlight.removeAll()` 直接丢掉回调数组,从不 resume。等待方用的是 `withCheckedContinuation`,
不响应取消——**每切一次文件夹就泄漏一批永久挂起的 Task**(`selectFolder` / `revealExternalImages` 都会调 `cancelAll`)。

**修法**:`cancelAll()` 里把 waiters 取出来逐个 `resume(returning: nil)`;
或者改用 `withTaskCancellationHandler` + 抛出型 continuation。

### P1-5 `pendingOtherCount` 在主线程扫盘

`FolderStore.pendingOtherCount` 是计算属性,被 `SidebarView` 的 body 直接读。
首次求值会走 `ImageDiscovery.imageCount(in:)` → `contentsOfDirectory` + `DispatchQueue.concurrentPerform`,
**全在主线程**。上千文件的文件夹,进入单图模式的第一次渲染会明显卡顿(之后有缓存)。

**修法**:改成一次性后台探测 + `@Observable` 状态落值,别让 body 触发 I/O。

### P1-6 缩略图解码失败 → 永久转圈

`ThumbCell` 里 `if thumb == nil { thumb = await ... }`,拿到 nil 后 `thumb` 仍是 nil,
条件永远成立,`.task(id:)` 只在 id 变化时重跑 → 那个格子**永远显示 ProgressView**。
权限受限、文件损坏、甚至某些 RAW 都会命中。

**修法**:加一个 `didFail` 状态,失败后画占位图标。

### P1-7 裸键快捷键在 sheet 打开时照常触发

`CommandMenu("图片")` 里的 `I` / `C` / `F` / `0` / `1` 都是无修饰键。
裁切 sheet 开着时按 `I` / `F` 会在背后切换信息面板和纯净模式;
打印面板里的输入框也可能吃掉/被吃。

**修法**:给这些 item 加 `.disabled(store.isSheetPresented)` 之类的条件,或者改用
`NSResponder` 的按键路由(只在画布是第一响应者时生效)。

### P1-8 删除无确认、隐藏不可逆

- `deleteImage()` 右键即移到废纸篓,**没有任何确认**。这个操作在缩略图右键菜单里,误触成本很高。
- `hideImage()` 隐藏后,会话内无法恢复:`selectFolder` 会重新套用 `hiddenByFolder` 过滤,
  `refreshCurrentFolder` 也不清空它。「刷新」并不能把隐藏的图找回来,只能重启 App。

**修法**:删除加 `NSAlert` 确认(或用 destructive 样式 + 二次点击);刷新时清空当前文件夹的 hidden 集合,
并在侧栏给一个「已隐藏 N 张 · 恢复」的入口。

---

## P2 — 交互优化点

**拖放与反馈**

1. `.onDrop` 传的是 `isTargeted: nil`,拖文件进来**没有任何视觉反馈**。加一个高亮描边,成本极低、感知极强。
2. 主画布**没有右键菜单**。用户会期望「复制 / 在 Finder 中显示 / 打印 / 裁切」,目前只有缩略图上有。
3. 滑动切图(触控板横滑、鼠标横拖)**全程没有跟手反馈**,松手才跳。建议拖动时让当前图跟着位移 + 松手回弹/翻页,
   否则 60pt 阈值在用户看来就是「拖了没反应」。

**裁切**

4. 手柄 11×11pt 偏小,且是纯白方块无描边——**在亮色照片上完全看不见**。建议视觉 8pt + 触控热区 20pt,加细描边。
5. 默认选区是 8% 内缩。多数场景用户想要「先全选再调整」,建议默认全图或给一个「全选」按钮。
6. 比例里缺「原始比例」,而这是最常用的一项。
7. 没有撤销。选区拖坏了只能点「重置」重来(`⌘Z` 无效)。
8. 预览加载失败但 `facts` 读成功时,`pixelSize > 0` 会让导出按钮可用,画布却永远停在
   「正在载入原图…」,点导出必失败——这是个死角状态,应该显式报错。

**浏览与导航**

9. 纯净模式(只看图)只有一个常驻的退出按钮。**建议改成鼠标移动时浮出的轻量 HUD**(文件名 + 序号 + 退出),
   静止后淡出——现在的常驻按钮在纯看图的场景下本身就有点碍眼。
10. 缩放下拉只有「适配窗口 / 实际大小」两项。既然已经展示了百分比,建议补 50% / 100% / 200%,
    并允许点百分比直接输入。目前点百分比只能开菜单,有点浪费这个位置。
11. **旋转是纯显示态**,切图即丢,而且不进裁切(CropView 从文件重新解码)。
    用户按了旋转再按裁切,旋转被静默丢弃。至少要在旋转生效时给个提示或提供「保存旋转后的副本」。
12. 排序选「拍摄时间」时是**两段式**:先按文件名出列表,后台读完 EXIF 再整体重排。
    列表会在用户眼前跳一次。建议加个「正在按拍摄时间排序…」的轻量提示,或等排完再一次性呈现。

**窗口与杂项**

13. 没有窗口位置/尺寸记忆(`frameAutosaveName`),每次打开都回到 1024×680。
14. 侧栏「缩略图」标题栏里有两个 `Spacer()`,展开/收起按钮浮在中间而不是靠右挨着数量。
15. `SettingsView` 里「排序」用了默认菜单样式、紧邻的「顺序」用了 `.radioGroup`,两个 Picker 长得不一样。
16. 顶栏写的是 "PureView",项目叫 Pictool、SPM target 叫 Pictool——命名三处不一致,打包脚本产出的也是 PureView.app。
17. `NativeTrafficLightsView` 用了私有 API `_setMouseInGroup:`。功能没问题,但上架会被拒,建议加 `#if` 降级路径。
18. 打印时全尺寸解码没有超时/取消,大图会一直转圈;那个 `ProgressView("正在准备打印…")` 还没有底色,
    在深色画布上可读性差。

---

## 建议的修复顺序

1. **P0-1**(裁切错位)——影响正确性,改动收口在一个函数,优先做。
2. **P0-2**(比例手柄跳动)——十几行,改动局部。
3. **P0-3**(100% 画质)——一行基准变量 + 阈值。
4. **P1-1 / P1-2 / P1-3**——都在显示链路,一起改。
5. **P1-4**(continuation 泄漏)——影响长时间使用的稳定性。
6. **P1-7 / P1-8**(快捷键 + 删除确认)——数据安全相关。
7. P2 按上面「拖放反馈 → 裁切打磨 → 浏览打磨」的顺序来。

其中 P0-1 和 P0-2 都适合补单测:`SourceFacts` 的 orientation 对调、
以及 `CropMath` 级别的比例约束锚点(可以把 `apply()` 的纯数学部分抽出来测,
目前它埋在 View 里没法测)。
