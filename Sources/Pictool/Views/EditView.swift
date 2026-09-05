import SwiftUI
import AppKit
import UniformTypeIdentifiers

// 统一编辑器(预览.app 式工具条):裁切 / 文字 / 画笔 / 马赛克 / 橡皮。
// 画布按工具切换;导出走 CropService(变换 → 烙印 → 裁切 → 水印)。

struct EditView: View {

    let file: ImageFile
    let initialQuarterTurns: Int
    var initialTool: EditTool = .text

    var onClose: () -> Void = {}

    init(file: ImageFile, initialQuarterTurns: Int, initialTool: EditTool = .text,
         onClose: @escaping () -> Void = {}) {
        self.file = file
        self.initialQuarterTurns = initialQuarterTurns
        self.initialTool = initialTool
        self.onClose = onClose
        _tool = State(initialValue: initialTool)
        _quarterTurns = State(initialValue: ((initialQuarterTurns % 4) + 4) % 4)
    }

    @Environment(FolderStore.self) private var store
    @Environment(AnnotationStore.self) private var annotationStore

    // 预览:base 为未变换的 1500px;display 为变换后
    @State private var basePreview: CGImage?
    @State private var displayCG: CGImage?
    @State private var displayPreview: NSImage?
    @State private var overlayImage: NSImage?
    @State private var previewFailed = false
    @State private var overlayGeneration = 0
    @State private var previewGeneration = 0
    @State private var transformedPixelSize = CGSize.zero

    // 变换
    @State private var quarterTurns = 0
    @State private var flipH = false
    @State private var flipV = false
    @State private var straighten = 0.0

    // 裁切选区(默认整图,未进裁切工具时导出整张)
    @State private var selection = CGRect(x: 0, y: 0, width: 1, height: 1)
    @State private var ratio: CropRatio = .free
    @State private var customW = "4"
    @State private var customH = "3"
    @FocusState private var editingCustomRatio: Bool

    // 标记状态
    @State private var annotations: [Annotation] = []
    @State private var selectedID: UUID?
    @State private var undoStack: [EditSnapshot] = []
    @State private var redoStack: [EditSnapshot] = []
    @State private var tool: EditTool = .text
    @State private var colorIndex = 2
    @State private var sizeLevel = 1
    @State private var mosaicEffect: MosaicEffect = .pixelate
    /// 画笔样式:实线 / 荧光(同一画笔工具的两种笔,不是两个工具)
    @State private var strokeStyle: StrokeStyleKind = .solid
    @State private var shapeKind: ShapeKind = .rect
    @State private var liveShapeTo: CGPoint?
    @State private var moveStartFrom = CGPoint.zero
    @State private var moveStartTo = CGPoint.zero
    @State private var livePoints: [CGPoint] = []
    @State private var erasedInGesture = false
    @State private var syncingControls = false
    @State private var selectingExisting = false
    @State private var grabOffset = CGSize.zero
    @State private var dragStartPoint: CGPoint?
    /// 拖动起点的整笔点位:笔迹移动从手势起点算绝对位移,避免逐帧漂移
    @State private var moveStartPoints: [CGPoint] = []
    /// 文字角柄改字号(B4):手势起点锚定比例,按对角距比值缩放
    @State private var textResizing = false
    @State private var resizeStartFraction: CGFloat = 0
    @State private var resizeStartDistance: CGFloat = 0
    /// 实时预览重绘节流(≥30ms 一帧):马赛克画线 / 移动 / 角柄缩放共用,尾帧补齐
    @State private var lastMosaicRebuild = Date.distantPast
    @State private var overlayRebuildTask: Task<Void, Never>?
    /// 右键菜单 action target 保活(NSMenuItem.target 不持有)
    @State private var contextBoxes: [ContextActionBox] = []

    // 文字草稿
    @State private var draftAnchor: CGPoint?
    @State private var draftContent = ""
    @State private var draftEditingID: UUID?
    @FocusState private var draftFocused: Bool

    // 画布视口(缩放/平移,B1)
    @State private var editZoom: CGFloat = 1
    @State private var editPan: CGSize = .zero
    @State private var canvasContainerSize: CGSize = .zero
    @State private var lastPanTranslation: CGPoint = .zero

    // 导出
    @State private var exporting = false
    @State private var errorMessage: String?
    @State private var format: CropFormat = .png
    @State private var quality = 0.92
    @State private var includeGPS = true
    @State private var watermarkDraft = WatermarkSettings()
    @State private var showWatermarkSettings = false
    @State private var showColorMenu = false
    @State private var showSizeMenu = false
    @State private var showMosaicMenu = false
    @State private var showStrokeStyleMenu = false
    @State private var showShapeMenu = false
    @State private var showCropMenu = false
    @State private var showExportPopover = false
    @State private var holdingWindowLock = false
    @AppStorage(CanvasBackground.storageKey) private var canvasBackground = CanvasBackground.defaultValue

    var body: some View {
        VStack(spacing: 0) {
            Rectangle()
                .fill(ChromeTheme.hairline(canvasBackground))
                .frame(height: 1)
            topBar
            canvasArea
        }
        .environment(\.colorScheme, ChromeTheme.colorScheme(for: canvasBackground))
        .background(ChromeTheme.fill(canvasBackground))
        .background(WindowBackgroundMoveLock(allowMove: false))
        .onAppear {
            tool = initialTool
            quarterTurns = ((initialQuarterTurns % 4) + 4) % 4
            annotations = annotationStore.annotations(for: file.url)
            watermarkDraft = WatermarkSettings.load()
            if !holdingWindowLock {
                holdingWindowLock = true
                WindowMoveControl.pushEditLock()
            }
        }
        .onDisappear {
            overlayRebuildTask?.cancel()
            if holdingWindowLock {
                holdingWindowLock = false
                WindowMoveControl.popEditLock()
            }
            store.isTextDraftActive = false
        }
        .task { loadPreview() }
        .onExitCommand { handleEscape() }
        .onChange(of: store.editTool) { _, newTool in
            switchTool(newTool)
        }
        .onChange(of: annotations) { _, new in
            annotationStore.set(new, for: file.url)
            scheduleOverlayRebuild()
        }
        .onChange(of: livePoints) { _, _ in
            guard tool == .mosaic else { return }
            scheduleOverlayRebuild()
        }
        .onChange(of: draftFocused) { _, focused in
            store.isTextDraftActive = focused
        }
        // 状态栏缩放控件(B1):与浏览模式同一入口
        .onChange(of: store.editZoomRequest?.token) { _, _ in
            guard let action = store.editZoomRequest?.action else { return }
            applyEditZoomAction(action)
        }
        .onChange(of: editZoom) { _, newZoom in
            store.editDisplayScale = newZoom
        }
        .onDisappear {
            store.editDisplayScale = 1
        }
        .onChange(of: selectedID) { _, _ in
            syncControlsFromSelection()
        }
        .onChange(of: draftEditingID) { _, _ in
            rebuildOverlay()
        }
        .onChange(of: watermarkDraft) { _, value in
            value.save()
        }
        .onChange(of: mosaicEffect) { _, effect in
            guard !syncingControls else { return }
            guard let id = selectedID,
                  let index = annotations.firstIndex(where: { $0.id == id }),
                  case let .mosaic(points, widthLevel, old) = annotations[index].kind,
                  old != effect else { return }
            pushUndo()
            annotations[index].kind = .mosaic(points: points, widthLevel: widthLevel, effect: effect)
        }
        .alert("导出失败", isPresented: .init(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("好", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    // MARK: 子视图

    private var topBar: some View {
        HStack(spacing: 8) {
            ForEach(EditTool.allCases) { t in
                Button {
                    switchTool(t)
                } label: {
                    Image(systemName: t.systemImage)
                        .frame(width: 26, height: 22)
                        .background {
                            if tool == t {
                                RoundedRectangle(cornerRadius: 5, style: .continuous)
                                    .fill(Color.accentColor.opacity(0.18))
                            }
                        }
                }
                .buttonStyle(.plain)
                .help(t.label)
            }

            Divider().frame(height: 16)

            attributeCluster

            Divider().frame(height: 16)

            Button { rotate(cw: false) } label: {
                Image(systemName: "rotate.left").frame(width: 22, height: 18)
            }
            .buttonStyle(.plain)
            .disabled(previewFailed)
            .help("逆时针旋转 90°")
            Button { rotate(cw: true) } label: {
                Image(systemName: "rotate.right").frame(width: 22, height: 18)
            }
            .buttonStyle(.plain)
            .disabled(previewFailed)
            .help("顺时针旋转 90°")
            Button { toggleFlipH() } label: {
                Image(systemName: "arrow.left.and.right.righttriangle.left.righttriangle.right")
                    .frame(width: 22, height: 18)
            }
            .buttonStyle(.plain)
            .disabled(previewFailed)
            .help("水平翻转")
            Button { toggleFlipV() } label: {
                Image(systemName: "arrow.up.and.down.righttriangle.left.righttriangle.right")
                    .frame(width: 22, height: 18)
            }
            .buttonStyle(.plain)
            .disabled(previewFailed)
            .help("垂直翻转")

            Divider().frame(height: 16)

            Button { undo() } label: {
                Image(systemName: "chevron.uturn.backward").frame(width: 22, height: 18)
            }
            .buttonStyle(.plain)
            .disabled(undoStack.isEmpty)
            .help("撤销 (⌘Z)")
            Button { redo() } label: {
                Image(systemName: "chevron.uturn.forward").frame(width: 22, height: 18)
            }
            .buttonStyle(.plain)
            .disabled(redoStack.isEmpty)
            .help("重做 (⇧⌘Z)")

            Spacer()

            // 水印独立入口:纯图标(无边框箭头),高度与颜色/大小 chip 一致;导出弹层里另有勾选项
            Button { showWatermarkSettings.toggle() } label: {
                Image(systemName: watermarkDraft.enabled && watermarkDraft.hasContent
                        ? "checkmark.seal.fill" : "seal")
                    .font(.system(size: 12))
                    .foregroundStyle(watermarkDraft.enabled && watermarkDraft.hasContent
                                     ? Color.accentColor : Color.primary)
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("水印设置(画布实时预览,导出时烙进像素)")
            .popover(isPresented: $showWatermarkSettings, arrowEdge: .bottom) {
                Form {
                    WatermarkSettingsForm(settings: $watermarkDraft)
                }
                .formStyle(.grouped)
                .frame(width: 360)
            }

            Menu {
                Button("存储为…") {
                    closeStyleMenus()
                    showWatermarkSettings = false
                    showExportPopover = true
                }
                if overwriteFormat != nil {
                    Button("覆盖原图", role: .destructive) {
                        closeStyleMenus()
                        showWatermarkSettings = false
                        export(overwrite: true)
                    }
                    .disabled(exporting || previewFailed)
                }
            } label: {
                Text("导出")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(exportReady ? 1 : 0.65))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(
                        // 与水印 chip 同一几何(12pt 字 + 4pt 垂直内边距),高度天然对齐
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(Color.accentColor.opacity(exportReady ? 1 : 0.4))
                    )
                    .contentShape(Rectangle())
            }
            // 纯按钮外观,点击任意处弹菜单(隐藏系统箭头指示器)
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .disabled(exporting || displayPreview == nil || previewFailed)
            .popover(isPresented: $showExportPopover, arrowEdge: .bottom) {
                ExportOptionsForm(
                    format: $format,
                    includeGPS: $includeGPS,
                    watermark: $watermarkDraft,
                    exporting: exporting,
                    onExport: {
                        showExportPopover = false
                        export(overwrite: false)
                    },
                    onWatermarkSettings: { showWatermarkSettings = true }
                )
            }

            // 退出:叉形图标,置于最右
            Button { onClose() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .medium))
                    .frame(width: 22, height: 18)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("退出编辑 (Esc)")
        }
        .padding(.horizontal, 12)
        .frame(height: 32)
        .background {
            ZStack {
                ChromeTheme.fill(canvasBackground)
                hiddenShortcuts
            }
        }
    }

    @ViewBuilder
    private var attributeCluster: some View {
        if tool == .text || tool == .brush {
            Button { showColorMenu.toggle() } label: {
                styleChip {
                    Circle()
                        .fill(Color(nsColor: MarkPalette.color(colorIndex)))
                        .frame(width: 12, height: 12)
                        .overlay(Circle().strokeBorder(Color.secondary.opacity(0.45), lineWidth: 0.5))
                }
            }
            .buttonStyle(.plain)
            .help("颜色")
            .popover(isPresented: $showColorMenu, arrowEdge: .bottom) { colorMenu }
        }
        if tool == .brush {
            Button { showStrokeStyleMenu.toggle() } label: {
                styleChip {
                    Text(strokeStyle.label).font(.system(size: 11))
                }
            }
            .buttonStyle(.plain)
            .help("笔样式")
            .popover(isPresented: $showStrokeStyleMenu, arrowEdge: .bottom) { strokeStyleMenu }
        }
        if tool == .mosaic {
            Button { showMosaicMenu.toggle() } label: {
                styleChip {
                    Text(mosaicEffect.label).font(.system(size: 11))
                }
            }
            .buttonStyle(.plain)
            .help("效果")
            .popover(isPresented: $showMosaicMenu, arrowEdge: .bottom) { mosaicMenu }
        }
        if tool == .shape {
            Button { showShapeMenu.toggle() } label: {
                styleChip {
                    Text(shapeKind.label).font(.system(size: 11))
                }
            }
            .buttonStyle(.plain)
            .help("形状")
            .popover(isPresented: $showShapeMenu, arrowEdge: .bottom) { shapeMenu }
        }
        if tool != .eraser && tool != .crop {
            Button { showSizeMenu.toggle() } label: {
                styleChip {
                    Image(systemName: "textformat.size").font(.system(size: 12))
                }
            }
            .buttonStyle(.plain)
            .help(levelLabel)
            .popover(isPresented: $showSizeMenu, arrowEdge: .bottom) { sizeMenu }
        }
        if tool == .crop {
            Button { showCropMenu.toggle() } label: {
                styleChip {
                    Text("裁切选项").font(.system(size: 11))
                }
            }
            .buttonStyle(.plain)
            .help("比例、拉直、翻转等原裁切功能")
            .popover(isPresented: $showCropMenu, arrowEdge: .bottom) { cropMenu }
        }
    }

    private func styleChip<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 3) {
            content()
            Image(systemName: "chevron.down")
                .font(.system(size: 7, weight: .bold))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .strokeBorder(Color.secondary.opacity(0.35))
        )
    }

    private var colorMenu: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("颜色").font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 8) {
                ForEach(MarkPalette.colors.indices, id: \.self) { i in
                    Circle()
                        .fill(Color(nsColor: MarkPalette.color(i)))
                        .frame(width: 18, height: 18)
                        .overlay(
                            Circle().strokeBorder(
                                colorIndex == i ? Color.accentColor : Color.secondary.opacity(0.4),
                                lineWidth: colorIndex == i ? 2 : 1
                            )
                        )
                        .onTapGesture { applyColorToSelection(i) }
                }
            }
        }
        .padding(10)
    }

    private var sizeMenu: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(levelLabel).font(.caption).foregroundStyle(.secondary)
            ForEach(["小", "中", "大"].indices, id: \.self) { i in
                Button {
                    sizeLevel = i
                    applySizeLevelToSelection()
                } label: {
                    HStack {
                        Text(["小", "中", "大"][i])
                        Spacer()
                        if sizeLevel == i {
                            Image(systemName: "checkmark").font(.caption)
                        }
                    }
                    .frame(minWidth: 88)
                }
                .buttonStyle(.plain)
                .padding(.vertical, 3)
            }
        }
        .padding(10)
    }

    private var mosaicMenu: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("效果").font(.caption).foregroundStyle(.secondary)
            ForEach(MosaicEffect.allCases) { effect in
                Button {
                    mosaicEffect = effect
                } label: {
                    HStack {
                        Text(effect.label)
                        Spacer()
                        if mosaicEffect == effect {
                            Image(systemName: "checkmark").font(.caption)
                        }
                    }
                    .frame(minWidth: 88)
                }
                .buttonStyle(.plain)
                .padding(.vertical, 3)
            }
        }
        .padding(10)
    }

    private var strokeStyleMenu: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("笔样式").font(.caption).foregroundStyle(.secondary)
            ForEach(StrokeStyleKind.allCases) { style in
                Button {
                    strokeStyle = style
                } label: {
                    HStack {
                        Text(style.label)
                        Spacer()
                        if strokeStyle == style {
                            Image(systemName: "checkmark").font(.caption)
                        }
                    }
                    .frame(minWidth: 88)
                }
                .buttonStyle(.plain)
                .padding(.vertical, 3)
            }
        }
        .padding(10)
    }

    private var shapeMenu: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("形状").font(.caption).foregroundStyle(.secondary)
            ForEach(ShapeKind.allCases) { kind in
                Button {
                    shapeKind = kind
                } label: {
                    HStack {
                        Text(kind.label)
                        Spacer()
                        if shapeKind == kind {
                            Image(systemName: "checkmark").font(.caption)
                        }
                    }
                    .frame(minWidth: 88)
                }
                .buttonStyle(.plain)
                .padding(.vertical, 3)
            }
        }
        .padding(10)
    }

    private var cropMenu: some View {
        VStack(alignment: .leading, spacing: 12) {
            // 旋转/翻转只在顶栏(唯一入口);这里只放裁切专属的拉直与选区
            HStack(spacing: 8) {
                Text("拉直").foregroundStyle(.secondary)
                Slider(value: $straighten, in: -45...45)
                    .frame(width: 140)
                    .disabled(previewFailed)
                    .onChange(of: straighten) { _, _ in scheduleStraightenPreview() }
                Text("\(straighten, specifier: "%.1f")°")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 44, alignment: .leading)
                Button("归零") { pushUndo(); straighten = 0; rebuildTransformedPreview() }
                    .disabled(straighten == 0 || previewFailed)
            }

            Divider()
            Text("选区").font(.caption).foregroundStyle(.secondary)
            HStack {
                Picker("比例", selection: $ratio) {
                    ForEach(CropRatio.allCases) { r in
                        Text(r.rawValue).tag(r)
                    }
                }
                .onChange(of: ratio) { _, newRatio in
                    if newRatio != .free { snapToRatio() }
                }
                Button { swapRatio() } label: {
                    Image(systemName: "arrow.left.arrow.right")
                }
                .buttonStyle(.plain)
                .disabled(!ratio.supportsSwap)
                .help("交换比例方向")
            }
            if ratio == .custom {
                HStack(spacing: 4) {
                    TextField("宽", text: $customW)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 46)
                        .multilineTextAlignment(.center)
                        .focused($editingCustomRatio)
                        .onSubmit { snapToRatio() }
                    Text(":").foregroundStyle(.secondary)
                    TextField("高", text: $customH)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 46)
                        .multilineTextAlignment(.center)
                        .focused($editingCustomRatio)
                        .onSubmit { snapToRatio() }
                }
            }
            HStack {
                if transformedPixelSize.width > 0 {
                    Text("\(Int(pixelRect.width.rounded())) × \(Int(pixelRect.height.rounded())) px")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("全选") { mutateSelection(CGRect(x: 0, y: 0, width: 1, height: 1)) }
                Button("重置") { mutateSelection(CGRect(x: 0.08, y: 0.08, width: 0.84, height: 0.84)) }
            }
        }
        .padding(12)
        .frame(minWidth: 320)
    }

    private func closeStyleMenus() {
        showColorMenu = false
        showSizeMenu = false
        showMosaicMenu = false
        showStrokeStyleMenu = false
        showShapeMenu = false
        showCropMenu = false
        showExportPopover = false
    }

    private var levelLabel: String {
        tool == .text ? "字号" : (tool == .mosaic ? "强度" : "粗细")
    }

    private var canvasArea: some View {
        ZStack {
            ChromeTheme.canvasFill(canvasBackground)
            if let displayPreview, transformedPixelSize.width > 0 {
                if tool == .crop {
                    ZStack {
                        CropCanvas(
                            image: displayPreview,
                            selection: $selection,
                            lockAspect: lockAspect,
                            previewAspect: displayPreview.size.width / max(1, displayPreview.size.height),
                            onInteractionStart: beginUndoGroup,
                            overlay: overlayImage,
                            watermark: liveWatermark
                        )
                    }
                } else {
                    MarkupCanvas(
                        image: displayPreview,
                        overlay: overlayImage,
                        annotations: annotations,
                        selectedID: selectedID,
                        tool: tool,
                        colorIndex: colorIndex,
                        sizeLevel: sizeLevel,
                        mosaicEffect: mosaicEffect,
                        strokeStyle: strokeStyle,
                        shapeKind: shapeKind,
                        livePoints: livePoints,
                        liveShapeFrom: tool == .shape ? dragStartPoint : nil,
                        liveShapeTo: liveShapeTo,
                        onTextResizeStart: handleTextResizeStart,
                        onTextResizeChange: handleTextResizeChange,
                        onTextResizeEnd: handleTextResizeEnd,
                        draftAnchor: draftAnchor,
                        draftContent: $draftContent,
                        draftEditingID: draftEditingID,
                        draftFocused: $draftFocused,
                        onDragStart: handleDragStart,
                        onDragChange: handleDragChange,
                        onDragEnd: handleDragEnd,
                        onDraftSubmit: { commitDraft() },
                        onCancel: handleEscape,
                        selection: selection,
                        watermark: liveWatermark,
                        zoom: editZoom,
                        pan: editPan,
                        hoverTest: tool == .crop ? nil : { point in
                            hitTest(at: point, kinds: [.text, .brush, .mosaic, .shape]) != nil
                        },
                        baseCursor: tool == .text ? .iBeam : .crosshair,
                        contextMenuProvider: tool == .crop ? nil : contextMenu(at:),
                        onScrollGesture: handleCanvasScroll,
                        onMagnifyGesture: handleCanvasMagnify,
                        onPanGesture: handleCanvasPan,
                        onPanGestureEnd: { lastPanTranslation = .zero },
                        onContainerChange: handleCanvasResize
                    )
                }
            } else if previewFailed {
                VStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 30))
                        .foregroundStyle(.secondary)
                    Text("无法载入此图的像素数据")
                        .foregroundStyle(.secondary)
                }
            } else {
                ProgressView("正在载入原图…")
            }

        }
        .frame(maxHeight: .infinity)
        // 缩放后图片不允许溢出画布区盖住顶栏/底栏
        .clipped()
    }

    /// 切工具保留选中(对齐预览.app);清草稿、弹层与全部手势残状态。
    private func switchTool(_ t: EditTool) {
        guard t != tool else { return }
        cancelDraft()
        closeStyleMenus()
        moveUndoPushed = false
        selectingExisting = false
        grabOffset = .zero
        dragStartPoint = nil
        moveStartPoints = []
        livePoints = []
        liveShapeTo = nil
        erasedInGesture = false
        tapCandidate = false
        tool = t
        // 回写给菜单 C/D 门禁与状态栏(顶栏切换不走 beginEdit 通道)
        store.editTool = t
    }

    /// ⌘Z/⇧⌘Z/⌫/Esc。文字草稿聚焦时撤销与删除让位给文本编辑,Esc 仍取消草稿。
    private var hiddenShortcuts: some View {
        Group {
            Button { undo() } label: { EmptyView() }
                .keyboardShortcut("z", modifiers: .command)
                .disabled(draftFocused)
            Button { redo() } label: { EmptyView() }
                .keyboardShortcut("z", modifiers: [.command, .shift])
                .disabled(draftFocused)
            Button { deleteSelected() } label: { EmptyView() }
                .keyboardShortcut(.delete, modifiers: [])
                .disabled(draftFocused || tool == .crop)
            Button { handleEscape() } label: { EmptyView() }
                .keyboardShortcut(.cancelAction)
            Button { switchTool(.text) } label: { EmptyView() }
                .keyboardShortcut("t", modifiers: [])
                .disabled(draftFocused)
            Button { switchTool(.brush) } label: { EmptyView() }
                .keyboardShortcut("b", modifiers: [])
                .disabled(draftFocused)
            Button { switchTool(.mosaic) } label: { EmptyView() }
                .keyboardShortcut("m", modifiers: [])
                .disabled(draftFocused)
            Button { switchTool(.eraser) } label: { EmptyView() }
                .keyboardShortcut("e", modifiers: [])
                .disabled(draftFocused)
            // ⌘⏎ 直达导出选项面板(融合后的菜单按钮不再有主操作区)
            Button { showExportPopover = true } label: { EmptyView() }
                .keyboardShortcut(.defaultAction)
                .disabled(draftFocused || exporting || displayPreview == nil || previewFailed)
            Button { resetCanvasViewport() } label: { EmptyView() }
                .keyboardShortcut("0", modifiers: .command)
                .disabled(draftFocused)
            Button { stepCanvasZoom(1.25) } label: { EmptyView() }
                .keyboardShortcut("=", modifiers: .command)
                .disabled(draftFocused)
            Button { stepCanvasZoom(1 / 1.25) } label: { EmptyView() }
                .keyboardShortcut("-", modifiers: .command)
                .disabled(draftFocused)
            Button { nudge(dx: -1, dy: 0) } label: { EmptyView() }
                .keyboardShortcut(.leftArrow, modifiers: [])
            Button { nudge(dx: 1, dy: 0) } label: { EmptyView() }
                .keyboardShortcut(.rightArrow, modifiers: [])
            Button { nudge(dx: 0, dy: -1) } label: { EmptyView() }
                .keyboardShortcut(.upArrow, modifiers: [])
            Button { nudge(dx: 0, dy: 1) } label: { EmptyView() }
                .keyboardShortcut(.downArrow, modifiers: [])
            Button { nudge(dx: -4, dy: 0) } label: { EmptyView() }
                .keyboardShortcut(.leftArrow, modifiers: .shift)
            Button { nudge(dx: 4, dy: 0) } label: { EmptyView() }
                .keyboardShortcut(.rightArrow, modifiers: .shift)
            Button { nudge(dx: 0, dy: -4) } label: { EmptyView() }
                .keyboardShortcut(.upArrow, modifiers: .shift)
            Button { nudge(dx: 0, dy: 4) } label: { EmptyView() }
                .keyboardShortcut(.downArrow, modifiers: .shift)
        }
        .disabled(editingCustomRatio)
        .opacity(0)
        .accessibilityHidden(true)
    }

    // MARK: 交互回调(归一化坐标)

    private func handleDragStart(at point: CGPoint) {
        if draftAnchor != nil { commitDraft(); return }
        erasedInGesture = false
        moveUndoPushed = false
        selectingExisting = false
        grabOffset = .zero
        dragStartPoint = point
        moveStartPoints = []
        switch tool {
        case .crop:
            break
        case .eraser:
            erase(at: point)
        case .text, .brush, .mosaic, .shape:
            if let hit = hitTest(at: point, kinds: [.text, .brush, .mosaic, .shape]) {
                selectedID = hit
                selectingExisting = true
                tapCandidate = false
                switch annotations.first(where: { $0.id == hit })?.kind {
                case let .text(anchor, _, _, _):
                    grabOffset = CGSize(width: point.x - anchor.x, height: point.y - anchor.y)
                case let .stroke(points, _, _, _):
                    moveStartPoints = points
                case let .mosaic(points, _, _):
                    moveStartPoints = points
                case let .shape(_, from, to, _, _):
                    moveStartFrom = from
                    moveStartTo = to
                default:
                    break
                }
            } else {
                selectNone()
                if tool == .text {
                    tapCandidate = true
                } else if tool == .shape {
                    liveShapeTo = point
                } else {
                    livePoints = [point]
                }
            }
        }
    }

    /// 起手位移小于阈值视为点击(不触发移动)
    private func withinTapThreshold(_ point: CGPoint) -> Bool {
        guard let start = dragStartPoint else { return false }
        return hypot(point.x - start.x, point.y - start.y) < 0.008
    }

    private func handleDragChange(at point: CGPoint) {
        switch tool {
        case .crop:
            break
        case .brush, .mosaic:
            if selectingExisting {
                guard !withinTapThreshold(point) else { return }
                moveSelected(to: point)
            } else {
                if let last = livePoints.last,
                   abs(point.x - last.x) < 0.0015, abs(point.y - last.y) < 0.0015 { return }
                livePoints.append(point)
            }
        case .shape:
            if selectingExisting {
                guard !withinTapThreshold(point) else { return }
                moveSelected(to: point)
            } else {
                liveShapeTo = point
            }
        case .eraser:
            erase(at: point)
        case .text:
            guard selectedID != nil, !withinTapThreshold(point) else { return }
            moveSelected(to: point)
        }
    }

    private func handleDragEnd(at point: CGPoint) {
        let start = dragStartPoint
        let movedFar: Bool = {
            guard let start else { return false }
            return hypot(point.x - start.x, point.y - start.y) >= 0.008
        }()
        switch tool {
        case .crop:
            break
        case .brush, .mosaic:
            if !selectingExisting { commitStroke() }
        case .shape:
            if !selectingExisting { commitShape(at: point) }
        case .eraser:
            break
        case .text:
            if selectingExisting, !movedFar {
                if let hit = selectedID, hit == lastTapID, Date().timeIntervalSince(lastTapTime) < 0.45 {
                    beginEdit(id: hit)
                }
                lastTapID = selectedID
                lastTapTime = Date()
            } else if tapCandidate, !movedFar, draftAnchor == nil {
                beginDraft(at: point)
                lastTapID = nil
                lastTapTime = Date()
            }
            tapCandidate = false
            moveUndoPushed = false
        }
        livePoints = []
        liveShapeTo = nil
        selectingExisting = false
        dragStartPoint = nil
    }

    /// 形状提交:起止距离过小视为误触不成形
    private func commitShape(at point: CGPoint) {
        guard let start = dragStartPoint else { return }
        guard hypot(point.x - start.x, point.y - start.y) >= 0.01 else { return }
        pushUndo()
        annotations.append(Annotation(kind: .shape(
            kind: shapeKind, from: start, to: point, widthLevel: sizeLevel, colorIndex: colorIndex
        )))
        selectedID = annotations.last?.id
    }

    private func handleEscape() {
        if draftAnchor != nil {
            cancelDraft()
        } else if selectedID != nil {
            selectNone()
        } else {
            onClose()
        }
    }

    // MARK: 右键菜单

    private func contextMenu(at point: CGPoint) -> NSMenu? {
        if draftAnchor != nil { commitDraft() }
        guard let hit = hitTest(at: point, kinds: [.text, .brush, .mosaic, .shape]) else { return nil }
        if selectedID != hit { selectedID = hit }
        let menu = NSMenu()
        contextBoxes.removeAll()
        if case .text = annotations.first(where: { $0.id == hit })?.kind {
            menu.addItem(menuItem("编辑文字") { beginEdit(id: hit) })
        }
        menu.addItem(menuItem("删除") { deleteSelected() })
        return menu
    }

    /// NSMenuItem.target 不持有 target,box 挂在 @State 数组上保活
    private func menuItem(_ title: String, handler: @escaping () -> Void) -> NSMenuItem {
        let box = ContextActionBox(handler: handler)
        contextBoxes.append(box)
        let item = NSMenuItem(
            title: title, action: #selector(ContextActionBox.perform(_:)), keyEquivalent: ""
        )
        item.target = box
        return item
    }

    @State private var tapCandidate = false
    @State private var lastTapID: UUID?
    @State private var lastTapTime = Date.distantPast

    // MARK: 命中与编辑

    private func hitTest(at point: CGPoint, kinds: [EditTool]) -> UUID? {
        guard let base = displayCG ?? basePreview else { return nil }
        let canvasSize = CGSize(width: base.width, height: base.height)
        for annotation in annotations.reversed() {
            guard let kind = kindOf(annotation), kinds.contains(kind) else { continue }
            switch annotation.kind {
            case let .text(anchor, content, sizeFraction, _):
                let bounds = MarkupGeometry.textHitRect(
                    anchor: anchor, content: content, sizeFraction: sizeFraction, imageSize: canvasSize
                )
                if bounds.insetBy(dx: -0.006, dy: -0.006).contains(point) { return annotation.id }
            case let .stroke(points, widthLevel, _, style):
                if MarkupGeometry.stroke(points, contains: point,
                                         widthFraction: MarkPalette.fraction(MarkPalette.widthTable(for: style), level: widthLevel),
                                         canvasSize: canvasSize) {
                    return annotation.id
                }
            case let .mosaic(points, widthLevel, _):
                if MarkupGeometry.stroke(points, contains: point,
                                         widthFraction: MarkPalette.fraction(MarkPalette.mosaicWidths, level: widthLevel),
                                         canvasSize: canvasSize) {
                    return annotation.id
                }
            case let .shape(kind, from, to, widthLevel, _):
                if MarkupGeometry.hitShape(kind: kind, from: from, to: to,
                                           widthFraction: MarkPalette.fraction(MarkPalette.strokeWidths, level: widthLevel),
                                           canvasSize: canvasSize, at: point) {
                    return annotation.id
                }
            }
        }
        return nil
    }

    private func kindOf(_ annotation: Annotation) -> EditTool? {
        switch annotation.kind {
        case .text: .text; case .stroke: .brush; case .mosaic: .mosaic; case .shape: .shape
        }
    }

    private func moveSelected(to point: CGPoint) {
        guard let id = selectedID,
              let index = annotations.firstIndex(where: { $0.id == id }) else { return }
        switch annotations[index].kind {
        case let .text(anchor, content, sizeFraction, colorIdx):
            // 文字从抓取偏移绝对定位(grabOffset 在手势起点固定),无逐帧漂移
            let target = CGPoint(x: point.x - grabOffset.width, y: point.y - grabOffset.height)
            let next = MarkupGeometry.moved(anchor: target, by: .zero)
            guard next != anchor else { return }
            pushUndoForMoveIfFirst()
            annotations[index].kind = .text(
                anchor: next, content: content, sizeFraction: sizeFraction, colorIndex: colorIdx
            )
        case let .stroke(_, widthLevel, colorIdx, style):
            guard let start = dragStartPoint else { return }
            let moved = MarkupGeometry.clampedTranslate(
                points: moveStartPoints,
                dx: point.x - start.x, dy: point.y - start.y
            )
            if case let .stroke(current, _, _, _) = annotations[index].kind, moved == current { return }
            pushUndoForMoveIfFirst()
            annotations[index].kind = .stroke(points: moved, widthLevel: widthLevel,
                                              colorIndex: colorIdx, style: style)
        case let .mosaic(_, widthLevel, effect):
            guard let start = dragStartPoint else { return }
            let moved = MarkupGeometry.clampedTranslate(
                points: moveStartPoints,
                dx: point.x - start.x, dy: point.y - start.y
            )
            if case let .mosaic(current, _, _) = annotations[index].kind, moved == current { return }
            pushUndoForMoveIfFirst()
            annotations[index].kind = .mosaic(points: moved, widthLevel: widthLevel, effect: effect)
        case let .shape(kind, _, _, widthLevel, colorIdx):
            guard let start = dragStartPoint else { return }
            let dx = point.x - start.x, dy = point.y - start.y
            let moved = MarkupGeometry.clampedTranslate(
                points: [moveStartFrom, moveStartTo], dx: dx, dy: dy
            )
            if case let .shape(_, from, to, _, _) = annotations[index].kind,
               moved[0] == from, moved[1] == to { return }
            pushUndoForMoveIfFirst()
            annotations[index].kind = .shape(kind: kind, from: moved[0], to: moved[1],
                                             widthLevel: widthLevel, colorIndex: colorIdx)
        }
    }

    @State private var moveUndoPushed = false
    private func pushUndoForMoveIfFirst() {
        guard !moveUndoPushed else { return }
        moveUndoPushed = true
        pushUndo()
    }

    private func beginEdit(id: UUID) {
        guard let annotation = annotations.first(where: { $0.id == id }),
              case let .text(anchor, content, _, _) = annotation.kind else { return }
        selectedID = id
        draftEditingID = id
        draftAnchor = anchor
        draftContent = content
        draftFocused = true
    }

    private func beginDraft(at point: CGPoint) {
        draftEditingID = nil
        draftAnchor = point
        draftContent = ""
        draftFocused = true
    }

    private func commitDraft() {
        guard let anchor = draftAnchor else { return }
        let content = draftContent.trimmingCharacters(in: .whitespacesAndNewlines)
        defer {
            draftAnchor = nil
            draftContent = ""
            draftEditingID = nil
            draftFocused = false
        }
        guard !content.isEmpty else { return }
        pushUndo()
        if let id = draftEditingID,
           let index = annotations.firstIndex(where: { $0.id == id }),
           case let .text(_, _, sizeFraction, colorIdx) = annotations[index].kind {
            annotations[index].kind = .text(anchor: anchor, content: content,
                                            sizeFraction: sizeFraction, colorIndex: colorIdx)
        } else {
            annotations.append(Annotation(kind: .text(
                anchor: anchor, content: content,
                sizeFraction: MarkPalette.fraction(MarkPalette.textSizes, level: sizeLevel),
                colorIndex: colorIndex
            )))
            selectedID = annotations.last?.id
        }
    }

    private func cancelDraft() {
        draftAnchor = nil
        draftContent = ""
        draftEditingID = nil
        draftFocused = false
    }

    // MARK: 笔迹 / 橡皮

    private func commitStroke() {
        guard !livePoints.isEmpty else { return }
        let simplified = MarkupGeometry.rdp(livePoints, epsilon: 0.002)
        guard !simplified.isEmpty else { return }
        pushUndo()
        switch tool {
        case .mosaic:
            annotations.append(Annotation(kind: .mosaic(
                points: simplified, widthLevel: sizeLevel, effect: mosaicEffect
            )))
        default:
            annotations.append(Annotation(kind: .stroke(
                points: simplified, widthLevel: sizeLevel, colorIndex: colorIndex,
                style: strokeStyle
            )))
        }
        selectedID = annotations.last?.id
    }

    private func erase(at point: CGPoint) {
        if let hit = hitTest(at: point, kinds: [.text, .brush, .mosaic, .shape]) {
            if !erasedInGesture {
                pushUndo()
                erasedInGesture = true
            }
            annotations.removeAll { $0.id == hit }
            if selectedID == hit { selectNone() }
        }
    }

    // MARK: 撤销 / 选中 / 删除

    private func syncControlsFromSelection() {
        guard let id = selectedID,
              let annotation = annotations.first(where: { $0.id == id }) else { return }
        syncingControls = true
        switch annotation.kind {
        case let .text(_, _, sizeFraction, colorIndex):
            self.sizeLevel = MarkPalette.nearestTextLevel(sizeFraction)
            self.colorIndex = colorIndex
        case let .stroke(_, widthLevel, colorIndex, style):
            self.sizeLevel = widthLevel
            self.colorIndex = colorIndex
            self.strokeStyle = style
        case let .mosaic(_, widthLevel, effect):
            self.sizeLevel = widthLevel
            self.mosaicEffect = effect
        case let .shape(_, _, _, widthLevel, colorIndex):
            self.sizeLevel = widthLevel
            self.colorIndex = colorIndex
        }
        syncingControls = false
    }

    private func applySizeLevelToSelection() {
        guard !syncingControls,
              let id = selectedID,
              let index = annotations.firstIndex(where: { $0.id == id }) else { return }
        switch annotations[index].kind {
        case let .text(anchor, content, old, colorIndex):
            let target = MarkPalette.fraction(MarkPalette.textSizes, level: sizeLevel)
            guard old != target else { return }
            pushUndo()
            annotations[index].kind = .text(anchor: anchor, content: content,
                                            sizeFraction: target, colorIndex: colorIndex)
        case let .stroke(points, old, colorIndex, style):
            guard old != sizeLevel else { return }
            pushUndo()
            annotations[index].kind = .stroke(points: points, widthLevel: sizeLevel,
                                              colorIndex: colorIndex, style: style)
        case let .mosaic(points, old, effect):
            guard old != sizeLevel else { return }
            pushUndo()
            annotations[index].kind = .mosaic(points: points, widthLevel: sizeLevel, effect: effect)
        case let .shape(kind, from, to, old, colorIndex):
            guard old != sizeLevel else { return }
            pushUndo()
            annotations[index].kind = .shape(kind: kind, from: from, to: to,
                                             widthLevel: sizeLevel, colorIndex: colorIndex)
        }
    }

    private func applyColorToSelection(_ newIndex: Int) {
        colorIndex = newIndex
        guard !syncingControls,
              let id = selectedID,
              let index = annotations.firstIndex(where: { $0.id == id }) else { return }
        switch annotations[index].kind {
        case let .text(anchor, content, sizeFraction, old):
            guard old != newIndex else { return }
            pushUndo()
            annotations[index].kind = .text(anchor: anchor, content: content,
                                            sizeFraction: sizeFraction, colorIndex: newIndex)
        case let .stroke(points, widthLevel, old, style):
            guard old != newIndex else { return }
            pushUndo()
            annotations[index].kind = .stroke(points: points, widthLevel: widthLevel,
                                              colorIndex: newIndex, style: style)
        case let .shape(kind, from, to, widthLevel, old):
            guard old != newIndex else { return }
            pushUndo()
            annotations[index].kind = .shape(kind: kind, from: from, to: to,
                                             widthLevel: widthLevel, colorIndex: newIndex)
        case .mosaic:
            break
        }
    }

    private func currentSnapshot() -> EditSnapshot {
        EditSnapshot(selection: selection, quarterTurns: quarterTurns, flipH: flipH, flipV: flipV,
                     straighten: straighten, annotations: annotations)
    }

    private func applySnapshot(_ snap: EditSnapshot) {
        let transformChanged = snap.quarterTurns != quarterTurns || snap.flipH != flipH
            || snap.flipV != flipV || snap.straighten != straighten
        selection = snap.selection
        quarterTurns = snap.quarterTurns
        flipH = snap.flipH
        flipV = snap.flipV
        straighten = snap.straighten
        annotations = snap.annotations
        if transformChanged { rebuildTransformedPreview() }
        else { rebuildOverlay() }
    }

    private func pushUndo() {
        undoStack.append(currentSnapshot())
        redoStack.removeAll()
    }

    private func beginUndoGroup() { pushUndo() }

    private func undo() {
        cancelDraft()
        guard let last = undoStack.popLast() else { return }
        redoStack.append(currentSnapshot())
        applySnapshot(last)
        selectNone()
    }

    private func redo() {
        cancelDraft()
        guard let next = redoStack.popLast() else { return }
        undoStack.append(currentSnapshot())
        applySnapshot(next)
        selectNone()
    }

    private func deleteSelected() {
        guard let id = selectedID else { return }
        pushUndo()
        annotations.removeAll { $0.id == id }
        selectNone()
    }

    private func selectNone() {
        selectedID = nil
        moveUndoPushed = false
        selectingExisting = false
    }

    // MARK: 预览 / 叠层

    private var pixelRect: CGRect {
        CropMath.pixelRect(normalized: selection, pixelSize: transformedPixelSize)
    }

    /// 画布水印:只有勾选「启用水印」且有内容时才叠到主图上。
    private var liveWatermark: WatermarkSettings {
        guard watermarkDraft.enabled, watermarkDraft.hasContent else { return WatermarkSettings() }
        return watermarkDraft
    }

    private var lockAspect: CGFloat? {
        let customAspect: CGFloat? = {
            guard let w = Double(customW), let h = Double(customH), w > 0, h > 0 else { return nil }
            return CGFloat(w / h)
        }()
        let imageAspect = transformedPixelSize.width / max(1, transformedPixelSize.height)
        return ratio.aspect(imageAspect: imageAspect, customAspect: customAspect)
    }

    private var overwriteFormat: CropFormat? {
        CropFormat.exactSourceExt(file.url.pathExtension)
    }

    private var exportReady: Bool {
        !exporting && displayPreview != nil && !previewFailed
    }

    private func rotate(cw: Bool) {
        cancelDraft()
        pushUndo()
        let map: (CGPoint) -> CGPoint = cw ? MarkupGeometry.rotateCW90 : MarkupGeometry.rotateCCW90
        annotations = annotations.map { MarkupGeometry.mapped($0, map) }
        quarterTurns += cw ? 1 : -1
        rebuildTransformedPreview()
    }

    private func toggleFlipH() {
        cancelDraft()
        pushUndo()
        annotations = annotations.map { MarkupGeometry.mapped($0, MarkupGeometry.flipH) }
        flipH.toggle()
        rebuildTransformedPreview()
    }

    private func toggleFlipV() {
        cancelDraft()
        pushUndo()
        annotations = annotations.map { MarkupGeometry.mapped($0, MarkupGeometry.flipV) }
        flipV.toggle()
        rebuildTransformedPreview()
    }

    private func mutateSelection(_ newValue: CGRect) {
        guard newValue != selection else { return }
        pushUndo()
        selection = newValue
    }

    private func nudge(dx: CGFloat, dy: CGFloat) {
        guard !previewFailed else { return }
        if tool == .crop {
            guard transformedPixelSize.width > 0 else { return }
            var r = selection
            r.origin.x = min(max(0, r.origin.x + dx * 0.005), 1 - r.width)
            r.origin.y = min(max(0, r.origin.y + dy * 0.005), 1 - r.height)
            mutateSelection(r)
            return
        }
        // 标注微调:选中对象按 0.002 步长平移(Shift ×4 由调用方传入)
        guard let id = selectedID,
              let index = annotations.firstIndex(where: { $0.id == id }) else { return }
        let delta = CGSize(width: dx * 0.002, height: dy * 0.002)
        switch annotations[index].kind {
        case let .text(anchor, content, sizeFraction, colorIdx):
            let next = MarkupGeometry.moved(anchor: anchor, by: delta)
            guard next != anchor else { return }
            pushUndo()
            annotations[index].kind = .text(anchor: next, content: content,
                                            sizeFraction: sizeFraction, colorIndex: colorIdx)
        case let .stroke(points, widthLevel, colorIdx, style):
            let next = MarkupGeometry.clampedTranslate(points: points, dx: delta.width, dy: delta.height)
            guard next != points else { return }
            pushUndo()
            annotations[index].kind = .stroke(points: next, widthLevel: widthLevel,
                                              colorIndex: colorIdx, style: style)
        case let .mosaic(points, widthLevel, effect):
            let next = MarkupGeometry.clampedTranslate(points: points, dx: delta.width, dy: delta.height)
            guard next != points else { return }
            pushUndo()
            annotations[index].kind = .mosaic(points: next, widthLevel: widthLevel, effect: effect)
        case let .shape(kind, from, to, widthLevel, colorIdx):
            let next = MarkupGeometry.clampedTranslate(points: [from, to], dx: delta.width, dy: delta.height)
            guard next[0] != from || next[1] != to else { return }
            pushUndo()
            annotations[index].kind = .shape(kind: kind, from: next[0], to: next[1],
                                             widthLevel: widthLevel, colorIndex: colorIdx)
        }
    }

    // MARK: 画布视口(缩放/平移)

    private var canvasImageAspect: CGFloat {
        transformedPixelSize.height > 0 ? transformedPixelSize.width / transformedPixelSize.height : 1
    }

    /// 滚轮:⌘ = 缩放(锚点视口中心由 MarkupCanvas 传容器后取中心),否则平移(方向随手指)。
    private func handleCanvasScroll(dx: CGFloat, dy: CGFloat, command: Bool, container: CGSize) {
        guard tool != .crop, displayPreview != nil, container.width > 0 else { return }
        if command {
            let factor = exp(-max(-60, min(60, dy)) * 0.01)
            applyCanvasZoom(factor: factor, anchor: CGPoint(x: container.width / 2, y: container.height / 2),
                            container: container)
        } else {
            editPan = EditCanvasMath.panned(pan: editPan, delta: CGSize(width: dx, height: dy),
                                            container: container, imageAspect: canvasImageAspect,
                                            zoom: editZoom)
        }
    }

    private func handleCanvasMagnify(factor: CGFloat, anchor: CGPoint, container: CGSize) {
        guard tool != .crop, displayPreview != nil else { return }
        applyCanvasZoom(factor: factor, anchor: anchor, container: container)
    }

    private func handleCanvasPan(translation: CGPoint, container: CGSize) {
        guard tool != .crop, displayPreview != nil else { return }
        let delta = CGSize(width: translation.x - lastPanTranslation.x,
                           height: translation.y - lastPanTranslation.y)
        lastPanTranslation = translation
        editPan = EditCanvasMath.panned(pan: editPan, delta: delta,
                                        container: container, imageAspect: canvasImageAspect,
                                        zoom: editZoom)
    }

    private func applyCanvasZoom(factor: CGFloat, anchor: CGPoint, container: CGSize) {
        let result = EditCanvasMath.zoomed(zoom: editZoom, pan: editPan, factor: factor,
                                           anchor: anchor, container: container,
                                           imageAspect: canvasImageAspect)
        editZoom = result.zoom
        editPan = result.pan
    }

    /// 窗口 resize:原视口中心处的内容点仍保持在新容器中心
    private func handleCanvasResize(_ newSize: CGSize) {
        let old = canvasContainerSize
        canvasContainerSize = newSize
        guard tool != .crop, displayPreview != nil, old.width > 0, old.height > 0,
              newSize.width > 0, newSize.height > 0, old != newSize else { return }
        let oldRect = EditCanvasMath.viewRect(container: old, imageAspect: canvasImageAspect,
                                              zoom: editZoom, pan: editPan)
        guard oldRect.width > 0, oldRect.height > 0 else { return }
        let u = (old.width / 2 - oldRect.minX) / oldRect.width
        let v = (old.height / 2 - oldRect.minY) / oldRect.height
        editPan = EditCanvasMath.panForCenteredContent(u: u, v: v, zoom: editZoom,
                                                       container: newSize,
                                                       imageAspect: canvasImageAspect)
    }

    private func resetCanvasViewport() {
        editZoom = 1
        editPan = .zero
    }

    /// 状态栏下拉的动作:适配窗口 / 倍率预设(相对适应窗口,居中)
    private func applyEditZoomAction(_ action: ZoomAction) {
        guard tool != .crop, displayPreview != nil else { return }
        switch action {
        case .fit, .actualSize:
            resetCanvasViewport()
        case .scale(let factor):
            editZoom = EditCanvasMath.clampedZoom(factor)
            editPan = .zero
        case .zoomIn:
            stepCanvasZoom(1.25)
        case .zoomOut:
            stepCanvasZoom(1 / 1.25)
        }
    }

    // MARK: 文字角柄改字号

    private func handleTextResizeStart(at point: CGPoint) {
        guard let id = selectedID,
              case let .text(anchor, _, fraction, _) = annotations.first(where: { $0.id == id })?.kind
        else { return }
        textResizing = true
        resizeStartFraction = MarkPalette.clampTextFraction(fraction)
        resizeStartDistance = max(0.02, hypot(point.x - anchor.x, point.y - anchor.y))
        moveUndoPushed = false
    }

    private func handleTextResizeChange(at point: CGPoint) {
        guard textResizing, let id = selectedID,
              let index = annotations.firstIndex(where: { $0.id == id }),
              case let .text(anchor, content, _, colorIdx) = annotations[index].kind else { return }
        let dist = max(0.02, hypot(point.x - anchor.x, point.y - anchor.y))
        let fraction = MarkPalette.clampTextFraction(resizeStartFraction * dist / resizeStartDistance)
        if case let .text(_, _, current, _) = annotations[index].kind, current == fraction { return }
        pushUndoForMoveIfFirst()
        annotations[index].kind = .text(anchor: anchor, content: content,
                                        sizeFraction: fraction, colorIndex: colorIdx)
    }

    private func handleTextResizeEnd() {
        textResizing = false
    }

    private func stepCanvasZoom(_ factor: CGFloat) {
        guard canvasContainerSize.width > 0 else { return }
        applyCanvasZoom(factor: factor,
                        anchor: CGPoint(x: canvasContainerSize.width / 2,
                                        y: canvasContainerSize.height / 2),
                        container: canvasContainerSize)
    }

    private func swapRatio() {        guard ratio.supportsSwap else { return }
        if ratio == .custom {
            let w = customW; customW = customH; customH = w
        } else if let pair = ratio.labelPair {
            customW = "\(pair.h)"
            customH = "\(pair.w)"
            ratio = .custom
        }
        snapToRatio()
    }

    private func snapToRatio() {
        guard let aspect = lockAspect, transformedPixelSize.width > 0 else { return }
        // 与拖动同一处换算:比例预设是像素空间的,选区是归一化坐标
        let imageAspect = transformedPixelSize.width / max(1, transformedPixelSize.height)
        let ratio = CropMath.normalizedAspect(aspect, imageAspect: imageAspect)
        var width = selection.width
        var height = width / ratio
        if height > selection.height {
            height = selection.height
            width = height * ratio
        }
        let x = selection.midX - width / 2
        let y = selection.midY - height / 2
        mutateSelection(CropMath.clampedNormalized(CGRect(x: x, y: y, width: width, height: height), minSize: 0.05))
    }

    private func loadPreview() {
        let url = file.url
        format = CropFormat.default(forSourceExt: url.pathExtension)
        Task {
            let image: NSImage? = await Task.detached(priority: .userInitiated) {
                (try? ImageLoader.decodeWithFacts(url: url, maxPixelSize: 1500))?.image
            }.value
            basePreview = image?.cgImage(forProposedRect: nil, context: nil, hints: nil)
            previewFailed = basePreview == nil
            rebuildTransformedPreview()
        }
    }

    private func rebuildTransformedPreview() {
        guard let base = basePreview else { return }
        previewGeneration += 1
        let gen = previewGeneration
        let turns = quarterTurns, fh = flipH, fv = flipV, deg = straighten
        Task {
            let img: CGImage? = await Task.detached(priority: .userInitiated) {
                CropTransform.apply(to: base, quarterTurns: turns, flipH: fh, flipV: fv, straightenDegrees: deg)
            }.value
            guard gen == previewGeneration, let img else { return }
            displayCG = img
            displayPreview = NSImage(cgImage: img, size: NSSize(width: img.width, height: img.height))
            transformedPixelSize = CGSize(width: img.width, height: img.height)
            rebuildOverlay()
        }
    }

    private func scheduleStraightenPreview() {
        previewGeneration += 1
        let gen = previewGeneration
        Task {
            try? await Task.sleep(for: .milliseconds(120))
            guard gen == previewGeneration else { return }
            rebuildTransformedPreview()
        }
    }

    private func overlayAnnotations() -> [Annotation] {
        var result = annotations
        if let editing = draftEditingID {
            result.removeAll { $0.id == editing }
        }
        if tool == .mosaic, livePoints.count >= 1 {
            result.append(Annotation(kind: .mosaic(
                points: livePoints, widthLevel: sizeLevel, effect: mosaicEffect
            )))
        }
        return result
    }

    /// 时间门槛节流 + 尾帧补齐:拖拽中的高频标注变化 ≥30ms 才全幅重绘一次,松手后的最终帧必达
    private func scheduleOverlayRebuild() {
        let now = Date()
        guard now.timeIntervalSince(lastMosaicRebuild) >= 0.03 else {
            overlayRebuildTask?.cancel()
            overlayRebuildTask = Task {
                try? await Task.sleep(for: .milliseconds(40))
                guard !Task.isCancelled else { return }
                lastMosaicRebuild = Date()
                rebuildOverlay()
            }
            return
        }
        lastMosaicRebuild = now
        rebuildOverlay()
    }

    private func rebuildOverlay() {
        guard let base = displayCG else { return }
        overlayGeneration += 1
        let gen = overlayGeneration
        let anns = overlayAnnotations()
        let size = CGSize(width: base.width, height: base.height)
        Task {
            let img: CGImage? = await Task.detached(priority: .userInitiated) {
                guard let ctx = CGContext(
                    data: nil, width: max(1, Int(size.width)), height: max(1, Int(size.height)),
                    bitsPerComponent: 8, bytesPerRow: 0,
                    space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                ) else { return nil }
                AnnotationRenderer.draw(anns, in: ctx, canvasSize: size, base: base)
                return ctx.makeImage()
            }.value
            guard gen == overlayGeneration else { return }
            if let img {
                overlayImage = NSImage(cgImage: img, size: NSSize(width: img.width, height: img.height))
            } else {
                overlayImage = nil
            }
        }
    }

    // MARK: 导出

    private func export(overwrite: Bool) {
        guard !exporting, displayPreview != nil, !previewFailed else { return }
        if draftAnchor != nil { commitDraft() }
        let fmt = overwrite ? (overwriteFormat ?? format) : format
        if overwrite {
            let confirm = NSAlert()
            confirm.messageText = "要覆盖原文件吗?"
            confirm.informativeText = annotations.isEmpty
                ? "“\(file.name)”将被编辑结果替换,原像素不可恢复。"
                : "“\(file.name)”将被裁切与标记结果替换,原像素不可恢复。"
            confirm.alertStyle = .warning
            let overwriteButton = confirm.addButton(withTitle: "覆盖原图")
            overwriteButton.hasDestructiveAction = true
            confirm.addButton(withTitle: "取消")
            guard confirm.runModal() == .alertFirstButtonReturn else { return }
        }

        var destURL: URL?
        if !overwrite {
            let panel = NSSavePanel()
            panel.canCreateDirectories = true
            panel.allowedContentTypes = [UTType(fmt.uti) ?? .png]
            let stem = file.url.deletingPathExtension().lastPathComponent
            panel.nameFieldStringValue = "\(stem)-编辑.\(fmt.fileExtension)"
            guard panel.runModal() == .OK, let dest = panel.url else { return }
            destURL = dest
        }

        exporting = true
        let url = file.url
        let anns = annotations
        let outFormat = overwrite ? fmt : format
        let q = quality
        let gps = includeGPS
        let turns = quarterTurns, fh = flipH, fv = flipV, deg = straighten
        let rect = selection
        let mark = watermarkDraft
        Task {
            let result = await Task.detached(priority: .userInitiated) { () -> Result<Data, Error> in
                Result {
                    try CropService.encode(
                        sourceURL: url, normalizedRect: rect, format: outFormat, quality: q,
                        quarterTurns: turns, flipH: fh, flipV: fv, straightenDegrees: deg,
                        maxLongestSide: nil, includeGPS: gps,
                        annotations: anns, watermark: mark
                    )
                }
            }.value
            exporting = false
            switch result {
            case .failure(let error):
                errorMessage = error.localizedDescription
            case .success(let data):
                await MainActor.run { save(data: data, overwrite: overwrite, format: outFormat, dest: destURL) }
            }
        }
    }

    @MainActor
    private func save(data: Data, overwrite: Bool, format: CropFormat, dest: URL?) {
        if overwrite {
            do {
                let temp = FileManager.default.temporaryDirectory
                    .appendingPathComponent(UUID().uuidString)
                    .appendingPathExtension(format.fileExtension)
                try data.write(to: temp, options: .atomic)
                if try FileManager.default.replaceItemAt(file.url, withItemAt: temp) == nil {
                    errorMessage = "替换原文件失败"
                    return
                }
                onClose()
            } catch {
                errorMessage = error.localizedDescription
            }
            return
        }
        guard let dest else { return }
        do {
            try data.write(to: dest, options: .atomic)
            onClose()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

/// 右键菜单 action 的 target:NSMenuItem 不持有 target,由调用方保活。
@MainActor
private final class ContextActionBox: NSObject {
    private let handler: () -> Void

    init(handler: @escaping () -> Void) {
        self.handler = handler
    }

    @objc func perform(_ sender: NSMenuItem?) {
        handler()
    }
}

/// 导出选项小弹层。选完格式后再弹出系统存储面板只选路径。
private struct ExportOptionsForm: View {
    @Binding var format: CropFormat
    @Binding var includeGPS: Bool
    @Binding var watermark: WatermarkSettings
    var exporting: Bool
    var onExport: () -> Void
    var onWatermarkSettings: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            VStack(spacing: 6) {
                HStack {
                    Text("格式")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Picker("格式", selection: $format) {
                        ForEach(CropFormat.allCases) { item in
                            Text(item.rawValue).tag(item)
                        }
                    }
                    .pickerStyle(.menu)
                    .controlSize(.small)
                    .labelsHidden()
                    .fixedSize()
                }
                HStack {
                    Text("位置信息")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Toggle("包含位置信息", isOn: $includeGPS)
                        .toggleStyle(.checkbox)
                        .controlSize(.small)
                        .labelsHidden()
                        .help("关闭后导出文件不带 GPS 坐标,EXIF 其余部分保留")
                }
                HStack {
                    Text("水印")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Toggle("启用水印", isOn: $watermark.enabled)
                        .toggleStyle(.checkbox)
                        .controlSize(.small)
                        .labelsHidden()
                        .disabled(!watermark.hasContent)
                        .help(watermark.hasContent ? "导出时把水印烙进像素(画布已实时预览)"
                              : "先在「设置…」里配置水印文字或 Logo")
                    Button("设置…") { onWatermarkSettings() }
                        .buttonStyle(.link)
                        .font(.system(size: 11))
                        .controlSize(.small)
                }
            }

            Button(action: onExport) {
                Text("存储…")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .keyboardShortcut(.defaultAction)
            .disabled(exporting)
        }
        .padding(12)
        .frame(width: 190)
    }
}

// MARK: - 标记画布

private struct MarkupCanvas: View {

    let image: NSImage
    let overlay: NSImage?
    let annotations: [Annotation]
    let selectedID: UUID?
    let tool: EditTool
    let colorIndex: Int
    let sizeLevel: Int
    let mosaicEffect: MosaicEffect
    let strokeStyle: StrokeStyleKind
    let shapeKind: ShapeKind
    let livePoints: [CGPoint]
    /// 形状实时预览:起点取自按下的 dragStartPoint,终点随手更新
    var liveShapeFrom: CGPoint?
    var liveShapeTo: CGPoint?
    /// 文字角柄改字号(B4):归一化坐标进出
    var onTextResizeStart: ((CGPoint) -> Void)?
    var onTextResizeChange: ((CGPoint) -> Void)?
    var onTextResizeEnd: (() -> Void)?
    let draftAnchor: CGPoint?
    @Binding var draftContent: String
    let draftEditingID: UUID?
    var draftFocused: FocusState<Bool>.Binding
    let onDragStart: (CGPoint) -> Void
    let onDragChange: (CGPoint) -> Void
    let onDragEnd: (CGPoint) -> Void
    let onDraftSubmit: () -> Void
    let onCancel: () -> Void
    var selection: CGRect = CGRect(x: 0, y: 0, width: 1, height: 1)
    var watermark: WatermarkSettings = WatermarkSettings()
    /// 视口缩放/平移(EditView 持有,裁切切换不销毁)
    var zoom: CGFloat = 1
    var pan: CGSize = .zero
    /// 悬停命中(归一化坐标进出);nil 表示无悬停手型提示
    var hoverTest: ((CGPoint) -> Bool)?
    /// 按工具的常规光标
    var baseCursor: NSCursor = .arrow
    /// 右键菜单(归一化坐标进出);nil 表示无
    var contextMenuProvider: ((CGPoint) -> NSMenu?)?
    /// 滚轮/捏合/空格拖(dx, dy, ⌘, 容器尺寸)等,容器尺寸由画布回传
    var onScrollGesture: ((_ dx: CGFloat, _ dy: CGFloat, _ command: Bool, _ container: CGSize) -> Void)?
    var onMagnifyGesture: ((_ factor: CGFloat, _ anchor: CGPoint, _ container: CGSize) -> Void)?
    var onPanGesture: ((_ translation: CGPoint, _ container: CGSize) -> Void)?
    var onPanGestureEnd: (() -> Void)?
    var onContainerChange: ((CGSize) -> Void)?

    var body: some View {
        GeometryReader { geo in
            let aspect = image.size.width / max(1, image.size.height)
            let fit = EditCanvasMath.viewRect(container: geo.size, imageAspect: aspect,
                                              zoom: zoom, pan: pan)
            let cropBox = CGRect(
                x: fit.minX + selection.minX * fit.width,
                y: fit.minY + selection.minY * fit.height,
                width: selection.width * fit.width,
                height: selection.height * fit.height
            )
            ZStack(alignment: .topLeading) {
                Image(nsImage: image)
                    .resizable()
                    .frame(width: fit.width, height: fit.height)
                    .offset(x: fit.minX, y: fit.minY)
                    .allowsHitTesting(false)

                if let overlay {
                    Image(nsImage: overlay)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: fit.width, height: fit.height)
                        .offset(x: fit.minX, y: fit.minY)
                        .allowsHitTesting(false)
                }

                WatermarkStampLayer(settings: watermark, frame: cropBox)

                selectionOutline(fit: fit)

                if !livePoints.isEmpty, tool != .mosaic {
                    liveStrokePath(fit: fit)
                }

                if tool == .shape, let from = liveShapeFrom, let to = liveShapeTo {
                    liveShapePath(kind: shapeKind, from: from, to: to, fit: fit)
                }

                CanvasMouseCatcher(
                    onDown: { point in pointerDown(point, fit: fit) },
                    onDrag: { point in pointerDrag(point, fit: fit) },
                    onUp: { pointerUp(fit: fit) },
                    baseCursor: baseCursor,
                    hoverHitTest: hoverTest.map { test in
                        { screenPoint in
                            fit.contains(screenPoint) && test(normalized(screenPoint, fit))
                        }
                    },
                    contextMenuProvider: contextMenuProvider.map { provider in
                        { screenPoint in
                            guard fit.contains(screenPoint) else { return nil }
                            return provider(normalized(screenPoint, fit))
                        }
                    },
                    onScroll: { dx, dy, command in
                        onScrollGesture?(dx, dy, command, geo.size)
                    },
                    onMagnify: { factor, anchor in
                        onMagnifyGesture?(factor, anchor, geo.size)
                    },
                    onPanStart: { },
                    onPanChange: { translation in
                        onPanGesture?(translation, geo.size)
                    },
                    onPanEnd: { onPanGestureEnd?() },
                    spacePanEnabled: !draftFocused.wrappedValue
                )
                .frame(width: geo.size.width, height: geo.size.height)

                // 草稿输入必须叠在捕获层之上,否则 TextField 点不到。
                if let anchor = draftAnchor {
                    draftEditor(anchor: anchor, fit: fit)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
            .onAppear { onContainerChange?(geo.size) }
            .onChange(of: geo.size) { _, newSize in
                onContainerChange?(newSize)
            }
            .onExitCommand { onCancel() }
        }
    }

    private func normalized(_ location: CGPoint, _ fit: CGRect) -> CGPoint {
        CGPoint(
            x: min(max(0, (location.x - fit.minX) / fit.width), 1),
            y: min(max(0, (location.y - fit.minY) / fit.height), 1)
        )
    }

    /// 角柄拖拽专用:不夹取,允许在手柄超出 fit 边缘时仍能按真实距离算字号
    private func normalizedUnclamped(_ location: CGPoint, _ fit: CGRect) -> CGPoint {
        CGPoint(x: (location.x - fit.minX) / fit.width,
                y: (location.y - fit.minY) / fit.height)
    }

    @State private var dragStarted = false
    @State private var lastPointer = CGPoint.zero
    /// 角柄拖拽路由:按下时命中手柄则本次手势全部走 resize 回调
    @State private var resizeRouting = false
    /// 草稿期间发生过任何按键(含 IME 组合):占位文字退场,避免与候选预览重叠
    @State private var draftInteracted = false

    private func pointerDown(_ point: CGPoint, fit: CGRect) {
        lastPointer = point
        guard fit.contains(point) else {
            dragStarted = false
            return
        }
        dragStarted = true
        if textResizeHandleHit(fit: fit, at: point) {
            resizeRouting = true
            onTextResizeStart?(normalizedUnclamped(point, fit))
            return
        }
        onDragStart(normalized(point, fit))
    }

    private func pointerDrag(_ point: CGPoint, fit: CGRect) {
        lastPointer = point
        guard dragStarted else { return }
        let normalizedPoint = normalized(point, fit)
        if resizeRouting {
            onTextResizeChange?(normalizedUnclamped(point, fit))
        } else {
            onDragChange(normalizedPoint)
        }
    }

    private func pointerUp(fit: CGRect) {
        if dragStarted {
            let normalizedPoint = normalized(lastPointer, fit)
            if resizeRouting {
                onTextResizeChange?(normalizedUnclamped(lastPointer, fit))
                onTextResizeEnd?()
                resizeRouting = false
            } else {
                onDragEnd(normalizedPoint)
            }
        }
        dragStarted = false
    }

    /// 选中文字时右下角手柄(容器坐标 ~9pt,不随缩放);命中半径 12pt
    private func textResizeHandleHit(fit: CGRect, at point: CGPoint) -> Bool {
        guard selectedIsText, let bounds = selectionBounds(fit: fit) else { return false }
        let center = CGPoint(x: bounds.maxX + 4.5, y: bounds.maxY + 4.5)
        return hypot(point.x - center.x, point.y - center.y) <= 12
    }

    private var selectedIsText: Bool {
        guard let id = selectedID,
              let annotation = annotations.first(where: { $0.id == id }) else { return false }
        if case .text = annotation.kind { return true }
        return false
    }

    /// 形状实时预览(SwiftUI Path,不进 overlay 重绘管线)
    private func liveShapePath(kind: ShapeKind, from: CGPoint, to: CGPoint, fit: CGRect) -> some View {
        func point(_ p: CGPoint) -> CGPoint {
            CGPoint(x: fit.minX + p.x * fit.width, y: fit.minY + p.y * fit.height)
        }
        func rect(_ r: CGRect) -> CGRect {
            CGRect(x: fit.minX + r.minX * fit.width, y: fit.minY + r.minY * fit.height,
                   width: r.width * fit.width, height: r.height * fit.height)
        }
        let widthFraction = MarkPalette.fraction(MarkPalette.strokeWidths, level: sizeLevel)
        let width = max(1, widthFraction * fit.width)
        let color = Color(nsColor: MarkPalette.color(colorIndex))
        let style = StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round)
        let canvas = CGSize(width: fit.width, height: fit.height)
        return Group {
            switch kind {
            case .rect:
                Path(rect(MarkupGeometry.standardizedRect(from: from, to: to))).stroke(color, style: style)
            case .ellipse:
                Path(ellipseIn: rect(MarkupGeometry.standardizedRect(from: from, to: to)))
                    .stroke(color, style: style)
            case .line, .arrow:
                Path { path in
                    path.move(to: point(from))
                    path.addLine(to: point(to))
                }
                .stroke(color, style: style)
                .overlay {
                    if kind == .arrow,
                       let head = MarkupGeometry.arrowHead(from: from, to: to,
                                                           widthFraction: widthFraction,
                                                           canvasSize: canvas) {
                        // 头部实心,与提交后的渲染一致
                        Path { path in
                            path.move(to: point(head.tip))
                            path.addLine(to: point(head.baseA))
                            path.addLine(to: point(head.baseB))
                            path.closeSubpath()
                        }
                        .fill(color)
                    }
                }
            }
        }
        .allowsHitTesting(false)
    }

    private func liveStrokePath(fit: CGRect) -> some View {
        let points = livePoints.map { p in
            CGPoint(x: fit.minX + p.x * fit.width, y: fit.minY + p.y * fit.height)
        }
        // 画笔样式:荧光 = 宽表 + 45% alpha,与导出渲染同一规则
        let style = strokeStyle
        let widthFraction = MarkPalette.fraction(MarkPalette.widthTable(for: style), level: sizeLevel)
        return Path { path in
            guard let first = points.first else { return }
            path.move(to: first)
            for p in points.dropFirst() { path.addLine(to: p) }
        }
        .stroke(
            Color(nsColor: MarkPalette.color(colorIndex))
                .opacity(style == .highlighter ? 0.45 : 1),
            style: StrokeStyle(lineWidth: max(1, widthFraction * fit.width),
                               lineCap: .round, lineJoin: .round)
        )
        .allowsHitTesting(false)
    }

    private func selectionBounds(fit: CGRect) -> CGRect? {
        guard let id = selectedID,
              let annotation = annotations.first(where: { $0.id == id }) else { return nil }
        let imageSize = image.size
        let normalizedBounds: CGRect?
        switch annotation.kind {
        case let .text(anchor, content, sizeFraction, _):
            normalizedBounds = MarkupGeometry.textHitRect(
                anchor: anchor, content: content, sizeFraction: sizeFraction, imageSize: imageSize
            )
        case let .stroke(points, widthLevel, _, style):
            normalizedBounds = MarkupGeometry.strokeBounds(
                points, widthFraction: MarkPalette.fraction(MarkPalette.widthTable(for: style), level: widthLevel)
            )
        case let .mosaic(points, widthLevel, _):
            normalizedBounds = MarkupGeometry.strokeBounds(
                points, widthFraction: MarkPalette.fraction(MarkPalette.mosaicWidths, level: widthLevel)
            )
        case let .shape(kind, from, to, widthLevel, _):
            normalizedBounds = MarkupGeometry.shapeBounds(
                kind: kind, from: from, to: to,
                widthFraction: MarkPalette.fraction(MarkPalette.strokeWidths, level: widthLevel),
                canvasSize: imageSize
            )
        }
        guard let b = normalizedBounds else { return nil }
        return CGRect(x: fit.minX + b.minX * fit.width,
                      y: fit.minY + b.minY * fit.height,
                      width: b.width * fit.width,
                      height: b.height * fit.height)
    }

    @ViewBuilder
    private func selectionOutline(fit: CGRect) -> some View {
        if let bounds = selectionBounds(fit: fit) {
            // 双层:白底衬深色虚线,浅色背景上也看得清
            ZStack {
                Rectangle()
                    .strokeBorder(Color.white.opacity(0.85), lineWidth: 2.2)
                Rectangle()
                    .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
            }
            .frame(width: bounds.width, height: bounds.height)
            .position(x: bounds.midX, y: bounds.midY)
            .overlay(alignment: .bottomTrailing) {
                // 文字角柄:拖拽改字号(容器坐标恒定尺寸)
                if selectedIsText {
                    RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                        .fill(Color.white)
                        .frame(width: 9, height: 9)
                        .overlay(
                            RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                                .strokeBorder(Color.black.opacity(0.55), lineWidth: 0.5)
                        )
                        .shadow(radius: 1)
                        .offset(x: 4.5, y: 4.5)
                }
            }
            .allowsHitTesting(false)
        }
    }

    private func draftEditor(anchor: CGPoint, fit: CGRect) -> some View {
        let fontSize = max(10, fit.width * MarkPalette.fraction(MarkPalette.textSizes, level: sizeLevel))
        let font = Font.system(size: fontSize, weight: .medium)
        // 占位提示自己叠 Text:macOS 上 TextField(prompt:) 的颜色在 plain 样式下不生效
        return ZStack(alignment: .leading) {
            if draftContent.isEmpty && !draftInteracted {
                Text("输入文字,回车确认")
                    .font(font)
                    // 占位是次级信息:60% 白,轻透但压得住底图
                    .foregroundStyle(.white.opacity(0.6))
                    .allowsHitTesting(false)
            }
            TextField("", text: $draftContent)
                .textFieldStyle(.plain)
                .font(font)
                .foregroundStyle(Color(nsColor: MarkPalette.color(colorIndex)))
                .focused(draftFocused)
                .onSubmit { onDraftSubmit() }
            // NSViewRepresentable 无固有尺寸,不给 frame 会撑满画布把草稿框撑爆
            DraftKeyProbe { draftInteracted = true }
                .frame(width: 0, height: 0)
        }
        .frame(width: max(120, fit.width * 0.4), alignment: .leading)
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background {
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(.ultraThinMaterial)
                // 强制深色磨砂:最轻一档,通透但有质感,深色底保证文字可读
                .environment(\.colorScheme, .dark)
                .overlay(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.12))
                )
        }
        .position(
            x: fit.minX + anchor.x * fit.width + max(60, fit.width * 0.2),
            y: fit.minY + anchor.y * fit.height + fontSize * 0.9
        )
        .onChange(of: anchor) { _, _ in draftInteracted = false }
    }
}

/// 草稿输入期间监听第一次按键:输入法组合文字不更新 binding,占位文字若不退场会与候选预览重叠。
/// 视图挂在草稿框里,随草稿创建/销毁,监听器生命周期与其一致。
private struct DraftKeyProbe: NSViewRepresentable {
    var onFirstKey: () -> Void

    func makeNSView(context: Context) -> ProbeView {
        let view = ProbeView()
        view.onFirstKey = onFirstKey
        return view
    }

    func updateNSView(_ nsView: ProbeView, context: Context) {
        nsView.onFirstKey = onFirstKey
    }

    final class ProbeView: NSView {
        var onFirstKey: (() -> Void)?
        private var monitor: Any?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window != nil, monitor == nil {
                monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] event in
                    self?.fireOnce()
                    return event
                }
            } else if window == nil {
                teardown()
            }
        }

        private func fireOnce() {
            guard let handler = onFirstKey else { return }
            teardown()
            onFirstKey = nil
            handler()
        }

        private func teardown() {
            if let monitor {
                NSEvent.removeMonitor(monitor)
                self.monitor = nil
            }
        }

        deinit { teardown() }
    }
}
