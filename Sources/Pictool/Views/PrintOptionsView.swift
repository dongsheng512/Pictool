import SwiftUI
import AppKit

/// 打印前选项:适配页面 / 实际大小,随后打开系统打印面板
struct PrintOptionsView: View {

    let file: ImageFile
    @Environment(\.dismiss) private var dismiss
    @State private var mode: PrintScaleMode = .fitPage
    @State private var preparing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("打印“\(file.name)”")
                .font(.headline)

            Picker("缩放", selection: $mode) {
                ForEach(PrintScaleMode.allCases) { m in
                    Text(m.rawValue).tag(m)
                }
            }
            .pickerStyle(.radioGroup)

            Text(mode == .fitPage
                 ? "缩放至页面可打印区域,单页居中输出。"
                 : "按图像原始尺寸输出,过大时自动分页。")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                Spacer()
                Button("取消") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button {
                    performPrint()
                } label: {
                    if preparing { ProgressView().controlSize(.small) } else { Text("打印…") }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(preparing)
            }
        }
        .padding(20)
        .frame(width: 360)
    }

    private func performPrint() {
        preparing = true
        let url = file.url
        let actual = mode == .actualSize
        Task {
            let image: NSImage? = await Task.detached(priority: .userInitiated) {
                try? ImageLoader.decode(url: url, maxPixelSize: actual ? nil : 4200)
            }.value
            preparing = false
            dismiss()
            if image == nil { return }
            // 等 sheet 关闭动画完成后再弹打印面板,避免模态冲突导致窗口卡死
            try? await Task.sleep(nanoseconds: 450_000_000)
            PrintService.print(image: image!, mode: mode)
        }
    }
}
