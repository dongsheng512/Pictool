import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// 裁切模式:独立全窗口 sheet,选区为归一化坐标(原点在图片左上)。
/// 选区坐标始终基于「变换后」的图幅:四分旋转/翻转/拉直只改像素映射,
/// 归一化选区不变,因此变换前后选区位置语义连续。
struct CropView: View {

    let file: ImageFile
    /// 主视图累计的显示旋转(每格 90°)。裁切直接带入同样的初始角度,
    /// 避免「主视图转了半天、进裁切全丢」的断裂体验。
    var initialQuarterTurns = 0
    @Environment(\.dismiss) private var dismiss

    // 选区
    @State private var selection = CGRect(x: 0.08, y: 0.08, width: 0.84, height: 0.84)
    @State private var ratio: CropRatio = .free
    @State private var customW = "4"
    @State private var customH = "3"
    @FocusState private var editingCustomRatio: Bool

    // 变换(预览与导出共用同一套参数,经 CropTransform 应用)
    @State private var quarterTurns = 0
    @State private var flipH = false
    @State private var flipV = false
    /// 拉直角度,-45...45,正值顺时针
    @State private var straighten = 0.0

    // 预览(1500px 降采样;变换后重渲染也在这个尺寸上做)
    @State private var basePreview: CGImage?
    @State private var displayPreview: NSImage?
    @State private var transformedPixelSize = CGSize.zero
    @State private var previewFailed = false
    @State private var previewGeneration = 0

    // 撤销/重做(只针对选区)
    @State private var undoStack: [CGRect] = []
    @State private var redoStack: [CGRect] = []

    // 导出
    @State private var exporting = false
    @State private var errorMessage: String?
    @State private var format: CropFormat = .png
    @State private var quality: Double = 0.92
    @State private var includeGPS = true
    @State private var maxSideText = ""

    var body: some View {
        VStack(spacing: 0) {
            topBar
            Divider()
            transformBar
            Divider()
            canvasArea
            Divider()
            bottomBar
        }
        .frame(minWidth: 820, minHeight: 560)
        .background(hiddenShortcuts)
        .task { loadPreview() }
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
        HStack(spacing: 10) {
            Picker("比例", selection: $ratio) {
                ForEach(CropRatio.allCases) { r in
                    Text(r.rawValue).tag(r)
                }
            }
            .pickerStyle(.menu)
            .frame(width: 92)
            .onChange(of: ratio) { _, newRatio in
                // 「原始」也要套一次,让选区对齐图片自身比例
                if newRatio != .free { snapToRatio() }
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

            // 交换比例方向:预设互换(4:3↔3:4),自定义互换输入值
            Button {
                swapRatio()
            } label: {
                Image(systemName: "arrow.left.arrow.right")
                    .frame(width: 22, height: 18)
            }
            .buttonStyle(.plain)
            .disabled(!ratio.supportsSwap)
            .help("交换比例方向(横↔竖)")

            Spacer()

            if transformedPixelSize.width > 0 {
                Text("\(Int(pixelRect.width.rounded())) × \(Int(pixelRect.height.rounded())) px")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            Button("全选") { mutateSelection(CGRect(x: 0, y: 0, width: 1, height: 1)) }
                .disabled(previewFailed)

            Button("重置") {
                mutateSelection(CGRect(x: 0.08, y: 0.08, width: 0.84, height: 0.84))
            }

            // 覆盖原图只在源格式可直接编码时提供,写回时沿用原格式
            if overwriteFormat != nil {
                Button("覆盖原图") { export(overwrite: true) }
                    .disabled(exporting || transformedPixelSize.width == 0 || previewFailed)
                    .help("把裁切结果写回原文件,原像素不可恢复")
            }

            Button("取消") { dismiss() }
                .keyboardShortcut(.cancelAction)

            Button {
                export(overwrite: false)
            } label: {
                if exporting { ProgressView().controlSize(.small) } else { Text("导出…") }
            }
            .keyboardShortcut(.defaultAction)
            .disabled(exporting || transformedPixelSize.width == 0 || previewFailed)
        }
        .padding(12)
    }

    /// 变换条:旋转 / 翻转 / 拉直 + 撤销重做
    private var transformBar: some View {
        HStack(spacing: 10) {
            Button {
                quarterTurns -= 1
            } label: {
                Image(systemName: "rotate.left").frame(width: 22, height: 18)
            }
            .buttonStyle(.plain)
            .disabled(previewFailed)
            .help("逆时针旋转 90°")

            Button {
                quarterTurns += 1
            } label: {
                Image(systemName: "rotate.right").frame(width: 22, height: 18)
            }
            .buttonStyle(.plain)
            .disabled(previewFailed)
            .help("顺时针旋转 90°")

            Button {
                flipH.toggle()
            } label: {
                Image(systemName: "arrow.left.and.right.righttriangle.left.righttriangle.right")
                    .frame(width: 22, height: 18)
            }
            .buttonStyle(.plain)
            .disabled(previewFailed)
            .help("水平翻转")

            Button {
                flipV.toggle()
            } label: {
                Image(systemName: "arrow.up.and.down.righttriangle.left.righttriangle.right")
                    .frame(width: 22, height: 18)
            }
            .buttonStyle(.plain)
            .disabled(previewFailed)
            .help("垂直翻转")

            Divider().frame(height: 14)

            Text("拉直").foregroundStyle(.secondary)
            Slider(value: $straighten, in: -45...45)
                .frame(width: 150)
                .disabled(previewFailed)
            Text("\(straighten, specifier: "%.1f")°")
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 48, alignment: .leading)
            Button("归零") { straighten = 0 }
                .disabled(straighten == 0 || previewFailed)

            Spacer()

            Button {
                undo()
            } label: {
                Image(systemName: "chevron.uturn.backward").frame(width: 22, height: 18)
            }
            .buttonStyle(.plain)
            .disabled(undoStack.isEmpty)
            .help("撤销 (⌘Z)")

            Button {
                redo()
            } label: {
                Image(systemName: "chevron.uturn.forward").frame(width: 22, height: 18)
            }
            .buttonStyle(.plain)
            .disabled(redoStack.isEmpty)
            .help("重做 (⇧⌘Z)")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .onChange(of: quarterTurns) { _, _ in rebuildTransformedPreview() }
        .onChange(of: flipH) { _, _ in rebuildTransformedPreview() }
        .onChange(of: flipV) { _, _ in rebuildTransformedPreview() }
        // 拉直拖动是连续值,防抖后重渲染,拖动手感流畅、预览略有延迟
        .onChange(of: straighten) { _, _ in scheduleStraightenPreview() }
    }

    private var canvasArea: some View {
        ZStack {
            Color.black.opacity(0.65)
            if let displayPreview, transformedPixelSize.width > 0 {
                CropCanvas(
                    image: displayPreview,
                    selection: $selection,
                    lockAspect: lockAspect,
                    previewAspect: displayPreview.size.width / max(1, displayPreview.size.height),
                    onInteractionStart: beginUndoGroup
                )
                .padding(20)
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
    }

    private var bottomBar: some View {
        HStack(spacing: 14) {
            LabeledContent("导出格式") {
                Picker("格式", selection: $format) {
                    ForEach(CropFormat.allCases) { f in
                        Text(f.rawValue).tag(f)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 240)
                .onChange(of: format) { _, _ in quality = 0.92 }
            }
            if format.isLossy {
                LabeledContent("质量") {
                    HStack {
                        Slider(value: $quality, in: 0.3...1.0)
                            .frame(width: 120)
                        Text("\(Int(quality * 100))%")
                            .font(.callout.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(width: 38)
                    }
                }
            }
            // 显式 HStack 而不是 LabeledContent:LabeledContent 在宽度吃紧时会把
            // 「最长边」标签折行、把 px 挤出可视区
            HStack(spacing: 5) {
                Text("最长边").foregroundStyle(.secondary).fixedSize()
                TextField("原始", text: $maxSideText)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 54)
                    .multilineTextAlignment(.trailing)
                Text("px").foregroundStyle(.secondary).fixedSize()
            }
            .help("导出时把最长边缩到该像素值,留空保持原始尺寸")

            Toggle("包含位置信息", isOn: $includeGPS)
                .help("关闭后导出文件不带 GPS 坐标,EXIF 其余部分保留")
            Spacer()
        }
        .padding(12)
    }

    /// 方向键微调选区 + 撤销快捷键。文字输入框聚焦时方向键要让位给光标移动。
    private var hiddenShortcuts: some View {
        Group {
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
            Button { undo() } label: { EmptyView() }
                .keyboardShortcut("z", modifiers: .command)
            Button { redo() } label: { EmptyView() }
                .keyboardShortcut("z", modifiers: [.command, .shift])
        }
        .disabled(editingCustomRatio)
    }

    // MARK: 逻辑

    private var pixelRect: CGRect {
        CropMath.pixelRect(normalized: selection, pixelSize: transformedPixelSize)
    }

    /// 比例锁定的目标宽高比;nil(自由/原始/自定义解析失败)时按自由处理
    private var lockAspect: CGFloat? {
        let customAspect: CGFloat? = {
            guard let w = Double(customW), let h = Double(customH), w > 0, h > 0 else { return nil }
            return CGFloat(w / h)
        }()
        let imageAspect = transformedPixelSize.width / max(1, transformedPixelSize.height)
        return ratio.aspect(imageAspect: imageAspect, customAspect: customAspect)
    }

    /// 覆盖原图只允许与源扩展名严格对应的格式;RAW/GIF 等不可编码格式不提供该入口
    private var overwriteFormat: CropFormat? {
        CropFormat.exactSourceExt(file.url.pathExtension)
    }

    private func loadPreview() {
        let url = file.url
        quarterTurns = ((initialQuarterTurns % 4) + 4) % 4
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
            displayPreview = NSImage(cgImage: img, size: NSSize(width: img.width, height: img.height))
            transformedPixelSize = CGSize(width: img.width, height: img.height)
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

    // MARK: 选区编辑(撤销栈)

    private func mutateSelection(_ newValue: CGRect) {
        guard newValue != selection else { return }
        undoStack.append(selection)
        redoStack.removeAll()
        selection = newValue
    }

    /// 画布拖动开始时由 Canvas 回调:把拖动前的选区压栈,整个拖动算一步
    private func beginUndoGroup() {
        undoStack.append(selection)
        redoStack.removeAll()
    }

    private func undo() {
        guard let last = undoStack.popLast() else { return }
        redoStack.append(selection)
        selection = last
    }

    private func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(selection)
        selection = next
    }

    /// 方向键微调:参数是步数(1 步 = 0.5%,⇧ 加速为 2%)
    private func nudge(dx: CGFloat, dy: CGFloat) {
        guard !previewFailed, transformedPixelSize.width > 0 else { return }
        var r = selection
        r.origin.x = min(max(0, r.origin.x + dx * 0.005), 1 - r.width)
        r.origin.y = min(max(0, r.origin.y + dy * 0.005), 1 - r.height)
        mutateSelection(r)
    }

    private func swapRatio() {
        guard ratio.supportsSwap else { return }
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
        var width = selection.width
        var height = width / aspect
        if height > selection.height {
            height = selection.height
            width = height * aspect
        }
        let x = selection.midX - width / 2
        let y = selection.midY - height / 2
        mutateSelection(CropMath.clampedNormalized(CGRect(x: x, y: y, width: width, height: height), minSize: 0.05))
    }

    // MARK: 导出

    private func export(overwrite: Bool) {
        guard !exporting, transformedPixelSize.width > 0, !previewFailed else { return }
        let fmt = overwrite ? (overwriteFormat ?? format) : format
        if overwrite {
            let confirm = NSAlert()
            confirm.messageText = "要覆盖原文件吗?"
            confirm.informativeText = "“\(file.name)”将被裁切结果替换,原像素不可恢复。"
            confirm.alertStyle = .warning
            let overwriteButton = confirm.addButton(withTitle: "覆盖原图")
            overwriteButton.hasDestructiveAction = true
            confirm.addButton(withTitle: "取消")
            guard confirm.runModal() == .alertFirstButtonReturn else { return }
        }
        exporting = true
        let url = file.url
        let rect = selection
        let q = quality
        let turns = quarterTurns, fh = flipH, fv = flipV, deg = straighten
        let maxSide = Int(maxSideText)
        let gps = includeGPS
        Task {
            let result = await Task.detached(priority: .userInitiated) { () -> Result<Data, Error> in
                Result {
                    try CropService.encode(
                        sourceURL: url, normalizedRect: rect, format: fmt, quality: q,
                        quarterTurns: turns, flipH: fh, flipV: fv,
                        straightenDegrees: deg, maxLongestSide: maxSide, includeGPS: gps
                    )
                }
            }.value
            exporting = false
            switch result {
            case .failure(let error):
                errorMessage = error.localizedDescription
            case .success(let data):
                await MainActor.run { save(data: data, overwrite: overwrite, format: fmt) }
            }
        }
    }

    @MainActor
    private func save(data: Data, overwrite: Bool, format: CropFormat) {
        if overwrite {
            do {
                // 先写临时文件再原子替换,避免写一半毁掉原图
                let temp = FileManager.default.temporaryDirectory
                    .appendingPathComponent(UUID().uuidString)
                    .appendingPathExtension(format.fileExtension)
                try data.write(to: temp, options: .atomic)
                if try FileManager.default.replaceItemAt(file.url, withItemAt: temp) == nil {
                    errorMessage = "替换原文件失败"
                    return
                }
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
            }
            return
        }
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.allowedContentTypes = [UTType(format.uti) ?? .png]
        let stem = file.url.deletingPathExtension().lastPathComponent
        panel.nameFieldStringValue = "\(stem)-裁切.\(format.fileExtension)"
        guard panel.runModal() == .OK, let dest = panel.url else { return }
        do {
            try data.write(to: dest, options: .atomic)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

// MARK: - 选区画布

private struct CropCanvas: View {

    let image: NSImage
    @Binding var selection: CGRect
    /// 比例锁定的目标宽高比;nil 时自由拖动
    let lockAspect: CGFloat?
    /// 预览图自身的宽高比(布局用,与比例锁定无关)
    let previewAspect: CGFloat
    /// 拖动真正开始改变选区时回调(压撤销栈,整个拖动算一步)
    let onInteractionStart: () -> Void

    @State private var dragBaseline: CGRect?
    @State private var undoGroupOpen = false

    var body: some View {
        GeometryReader { geo in
            let fit = fittedRect(container: geo.size)
            ZStack(alignment: .topLeading) {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: fit.width, height: fit.height)
                    .position(x: fit.midX, y: fit.midY)

                dimming(fit: fit)
                selectionOverlay(fit: fit)
            }
        }
        .aspectRatio(previewAspect, contentMode: .fit)
    }

    private func fittedRect(container: CGSize) -> CGRect {
        let aspect = previewAspect > 0 ? previewAspect : 1
        let scale = min(container.width / aspect, container.height)
        let width = aspect * scale
        let height = scale
        return CGRect(x: (container.width - width) / 2,
                      y: (container.height - height) / 2,
                      width: width, height: height)
    }

    /// 选区之外的半透明遮罩(奇偶填充)
    private func dimming(fit: CGRect) -> some View {
        Path { path in
            path.addRect(CGRect(origin: .zero, size: CGSize(width: fit.maxX, height: fit.maxY)))
            path.addRect(displayRect(fit: fit))
        }
        .fill(Color.black.opacity(0.5), style: FillStyle(eoFill: true))
        .allowsHitTesting(false)
    }

    private func displayRect(fit: CGRect) -> CGRect {
        CGRect(x: fit.minX + selection.minX * fit.width,
               y: fit.minY + selection.minY * fit.height,
               width: selection.width * fit.width,
               height: selection.height * fit.height)
    }

    private func selectionOverlay(fit: CGRect) -> some View {
        let rect = displayRect(fit: fit)
        let minNorm = max(0.02, 18 / fit.width)
        return ZStack {
            // 三分线
            Path { p in
                for i in 1...2 {
                    let x = rect.minX + rect.width * CGFloat(i) / 3
                    let y = rect.minY + rect.height * CGFloat(i) / 3
                    p.move(to: CGPoint(x: x, y: rect.minY)); p.addLine(to: CGPoint(x: x, y: rect.maxY))
                    p.move(to: CGPoint(x: rect.minX, y: y)); p.addLine(to: CGPoint(x: rect.maxX, y: y))
                }
            }
            .stroke(Color.white.opacity(0.45), lineWidth: 0.5)
            .allowsHitTesting(false)

            Rectangle()
                .strokeBorder(Color.white, lineWidth: 1.5)
                .frame(width: rect.width, height: rect.height)
                .position(x: rect.midX, y: rect.midY)
                .contentShape(Rectangle())
                .gesture(dragGesture(kind: .move, fit: fit, minNorm: minNorm))

            ForEach(Array(handleSpecs(fit: fit, rect: rect).enumerated()), id: \.offset) { _, spec in
                // 视觉尺寸保持精致,但触控热区放大到 20pt——11pt 的方块很难抓准。
                // 再加一圈深色描边:纯白手柄在亮色照片上完全看不见。
                ZStack {
                    Rectangle()
                        .fill(Color.white)
                        .frame(width: spec.size, height: spec.size)
                        .overlay(
                            Rectangle()
                                .strokeBorder(Color.black.opacity(0.55), lineWidth: 0.5)
                                .frame(width: spec.size, height: spec.size)
                        )
                        .shadow(radius: 1)
                }
                .frame(width: 20, height: 20)
                .contentShape(Rectangle())
                .position(spec.point)
                .gesture(dragGesture(kind: spec.kind, fit: fit, minNorm: minNorm))
            }
        }
    }

    private struct HandleSpec {
        let kind: CropHandle
        let point: CGPoint
        let size: CGFloat
    }

    private func handleSpecs(fit: CGRect, rect: CGRect) -> [HandleSpec] {
        let corner: CGFloat = 11
        let edge: CGFloat = 8
        return [
            HandleSpec(kind: .topLeft, point: CGPoint(x: rect.minX, y: rect.minY), size: corner),
            HandleSpec(kind: .topRight, point: CGPoint(x: rect.maxX, y: rect.minY), size: corner),
            HandleSpec(kind: .bottomLeft, point: CGPoint(x: rect.minX, y: rect.maxY), size: corner),
            HandleSpec(kind: .bottomRight, point: CGPoint(x: rect.maxX, y: rect.maxY), size: corner),
            HandleSpec(kind: .top, point: CGPoint(x: rect.midX, y: rect.minY), size: edge),
            HandleSpec(kind: .bottom, point: CGPoint(x: rect.midX, y: rect.maxY), size: edge),
            HandleSpec(kind: .left, point: CGPoint(x: rect.minX, y: rect.midY), size: edge),
            HandleSpec(kind: .right, point: CGPoint(x: rect.maxX, y: rect.midY), size: edge),
        ]
    }

    private func dragGesture(kind: CropHandle, fit: CGRect, minNorm: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if dragBaseline == nil { dragBaseline = selection }
                if !undoGroupOpen {
                    undoGroupOpen = true
                    onInteractionStart()
                }
                guard let base = dragBaseline else { return }
                let dx = value.translation.width / fit.width
                let dy = value.translation.height / fit.height
                apply(kind: kind, base: base, dx: dx, dy: dy, minNorm: minNorm)
            }
            .onEnded { _ in
                dragBaseline = nil
                undoGroupOpen = false
            }
    }

    private func apply(kind: CropHandle, base: CGRect, dx: CGFloat, dy: CGFloat, minNorm: CGFloat) {
        var minX = base.minX, minY = base.minY
        var maxX = base.maxX, maxY = base.maxY
        switch kind {
        case .move:
            minX += dx; maxX += dx; minY += dy; maxY += dy
        case .topLeft: minX += dx; minY += dy
        case .topRight: maxX += dx; minY += dy
        case .bottomLeft: minX += dx; maxY += dy
        case .bottomRight: maxX += dx; maxY += dy
        case .top: minY += dy
        case .bottom: maxY += dy
        case .left: minX += dx
        case .right: maxX += dx
        }
        let free = CGRect(x: min(minX, maxX), y: min(minY, maxY),
                          width: abs(maxX - minX), height: abs(maxY - minY))

        // 比例约束:锚点、尺寸、夹取全部收口在纯函数里(可单测)
        if let aspect = lockAspect {
            selection = CropMath.ratioLockedRect(free: free, base: base, handle: kind,
                                                 aspect: aspect, minSize: minNorm)
        } else {
            selection = CropMath.clampedNormalized(free, minSize: minNorm)
        }
    }
}
