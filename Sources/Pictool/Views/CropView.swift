import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// 裁切模式:独立全窗口 sheet,选区为归一化坐标(原点在图片左上)
struct CropView: View {

    let file: ImageFile
    @Environment(\.dismiss) private var dismiss

    @State private var selection = CGRect(x: 0.08, y: 0.08, width: 0.84, height: 0.84)
    @State private var ratio: CropRatio = .free
    @State private var preview: NSImage?
    @State private var pixelSize = CGSize.zero
    @State private var exporting = false
    @State private var errorMessage: String?
    @State private var format: CropFormat = .png
    @State private var quality: Double = 0.92

    var body: some View {
        VStack(spacing: 0) {
            topBar
            Divider()
            canvasArea
            Divider()
            bottomBar
        }
        .frame(minWidth: 760, minHeight: 520)
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
        HStack(spacing: 12) {
            Picker("比例", selection: $ratio) {
                ForEach(CropRatio.allCases) { r in
                    Text(r.rawValue).tag(r)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 380)
            .onChange(of: ratio) { _, _ in snapToRatio() }

            Spacer()

            if pixelSize.width > 0 {
                Text("\(Int(pixelRect.width.rounded())) × \(Int(pixelRect.height.rounded())) px")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            Button("重置") { selection = CGRect(x: 0.08, y: 0.08, width: 0.84, height: 0.84) }

            Button("取消") { dismiss() }
                .keyboardShortcut(.cancelAction)

            Button {
                export()
            } label: {
                if exporting { ProgressView().controlSize(.small) } else { Text("导出…") }
            }
            .keyboardShortcut(.defaultAction)
            .disabled(exporting || pixelSize.width == 0)
        }
        .padding(12)
    }

    private var canvasArea: some View {
        ZStack {
            Color.black.opacity(0.65)
            if let preview, pixelSize.width > 0 {
                CropCanvas(
                    image: preview,
                    selection: $selection,
                    ratio: ratio,
                    imageAspect: pixelSize.width / pixelSize.height
                )
                .padding(20)
            } else {
                ProgressView("正在载入原图…")
            }
        }
        .frame(maxHeight: .infinity)
    }

    private var bottomBar: some View {
        HStack(spacing: 16) {
            LabeledContent("导出格式") {
                Picker("格式", selection: $format) {
                    ForEach(CropFormat.allCases) { f in
                        Text(f.rawValue).tag(f)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 260)
                .onChange(of: format) { _, _ in quality = 0.92 }
            }
            if format.isLossy {
                LabeledContent("质量") {
                    HStack {
                        Slider(value: $quality, in: 0.3...1.0)
                            .frame(width: 140)
                        Text("\(Int(quality * 100))%")
                            .font(.callout.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(width: 38)
                    }
                }
            }
            Spacer()
        }
        .padding(12)
    }

    // MARK: 逻辑

    private var pixelRect: CGRect {
        CropMath.pixelRect(normalized: selection, pixelSize: pixelSize)
    }

    private func loadPreview() {
        let url = file.url
        Task {
            let (image, facts): (NSImage?, ImageLoader.SourceFacts) = await Task.detached(priority: .userInitiated) {
                if let decoded = try? ImageLoader.decodeWithFacts(url: url, maxPixelSize: 1500) {
                    return (decoded.image, decoded.facts)
                }
                return (nil, ImageLoader.facts(of: url))
            }.value
            preview = image
            pixelSize = CGSize(width: facts.pixelWidth, height: facts.pixelHeight)
            format = CropFormat.default(forSourceExt: url.pathExtension)
        }
    }

    private func snapToRatio() {
        guard ratio != .free, pixelSize.width > 0 else { return }
        let aspect = ratioAspect()
        var width = selection.width
        var height = width / aspect
        if height > selection.height {
            height = selection.height
            width = height * aspect
        }
        let x = selection.midX - width / 2
        let y = selection.midY - height / 2
        selection = CropMath.clampedNormalized(CGRect(x: x, y: y, width: width, height: height), minSize: 0.05)
    }

    private func ratioAspect() -> CGFloat {
        switch ratio {
        case .free: return pixelSize.width / max(1, pixelSize.height)
        case .square: return 1
        case .fourBy3: return 4.0 / 3.0
        case .threeBy4: return 3.0 / 4.0
        case .sixteenBy9: return 16.0 / 9.0
        case .nineBy16: return 9.0 / 16.0
        }
    }

    private func export() {
        exporting = true
        let url = file.url
        let rect = selection
        let fmt = format
        let q = quality
        Task {
            let result = await Task.detached(priority: .userInitiated) { () -> Result<Data, Error> in
                Result { try CropService.encode(sourceURL: url, normalizedRect: rect, format: fmt, quality: q) }
            }.value
            exporting = false
            switch result {
            case .failure(let error):
                errorMessage = error.localizedDescription
            case .success(let data):
                await MainActor.run { save(data: data) }
            }
        }
    }

    @MainActor
    private func save(data: Data) {
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

private enum HandleKind {
    case move, topLeft, topRight, bottomLeft, bottomRight, top, bottom, left, right
}

private struct CropCanvas: View {

    let image: NSImage
    @Binding var selection: CGRect
    let ratio: CropRatio
    let imageAspect: CGFloat

    @State private var dragBaseline: CGRect?

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
        .aspectRatio(imageAspect, contentMode: .fit)
    }

    private func fittedRect(container: CGSize) -> CGRect {
        let scale = min(container.width / imageAspect, container.height)
        let width = imageAspect * scale
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
                Rectangle()
                    .fill(Color.white)
                    .frame(width: spec.size, height: spec.size)
                    .shadow(radius: 1)
                    .position(spec.point)
                    .gesture(dragGesture(kind: spec.kind, fit: fit, minNorm: minNorm))
            }
        }
    }

    private struct HandleSpec {
        let kind: HandleKind
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

    private func dragGesture(kind: HandleKind, fit: CGRect, minNorm: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if dragBaseline == nil { dragBaseline = selection }
                guard let base = dragBaseline else { return }
                let dx = value.translation.width / fit.width
                let dy = value.translation.height / fit.height
                apply(kind: kind, base: base, dx: dx, dy: dy, minNorm: minNorm)
            }
            .onEnded { _ in dragBaseline = nil }
    }

    private func apply(kind: HandleKind, base: CGRect, dx: CGFloat, dy: CGFloat, minNorm: CGFloat) {
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
        var rect = CGRect(x: min(minX, maxX), y: min(minY, maxY),
                          width: abs(maxX - minX), height: abs(maxY - minY))

        // 比例约束:以拖动对侧的边/角为锚点
        if ratio != .free {
            let aspect = ratioAspectValue
            let anchorX: CGFloat = (kind == .topLeft || kind == .bottomLeft || kind == .left) ? base.maxX
                : (kind == .right || kind == .topRight || kind == .bottomRight) ? base.minX : rect.midX
            let anchorY: CGFloat = (kind == .topLeft || kind == .topRight || kind == .top) ? base.maxY
                : (kind == .bottom || kind == .bottomLeft || kind == .bottomRight) ? base.minY : rect.midY
            var width = rect.width
            var height = width / aspect
            if kind == .top || kind == .bottom {
                height = rect.height
                width = height * aspect
            } else if height > rect.height {
                height = rect.height
                width = height * aspect
            }
            let x = kind == .move ? rect.midX - width / 2 : anchorX + (anchorX == base.minX ? 0 : -width)
            let y = kind == .move ? rect.midY - height / 2 : anchorY + (anchorY == base.minY ? 0 : -height)
            rect = CGRect(x: x, y: y, width: width, height: height)
        }

        selection = CropMath.clampedNormalized(rect, minSize: minNorm)
    }

    private var ratioAspectValue: CGFloat {
        switch ratio {
        case .free: return imageAspect
        case .square: return 1
        case .fourBy3: return 4.0 / 3.0
        case .threeBy4: return 3.0 / 4.0
        case .sixteenBy9: return 16.0 / 9.0
        case .nineBy16: return 9.0 / 16.0
        }
    }
}
