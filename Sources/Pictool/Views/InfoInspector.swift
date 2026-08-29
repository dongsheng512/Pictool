import SwiftUI
import AppKit

/// 右侧信息面板:文件 / 图像 / 拍摄信息(EXIF) / GPS,支持一键复制
struct InfoInspector: View {

    let file: ImageFile?
    @State private var info: ImageInfo?
    // 窗口背景是透明的(.inspector 会透出去),面板自己铺当前画布背景色;AppStorage 保证设置里改背景时实时同步
    @AppStorage(CanvasBackground.storageKey) private var canvasBackground = CanvasBackground.defaultValue

    var body: some View {
        Group {
            if let file {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        if let info {
                            ForEach(info.sections) { section in
                                sectionView(section)
                            }
                        } else {
                            HStack {
                                Spacer()
                                ProgressView()
                                Spacer()
                            }
                            .padding(.top, 30)
                        }
                    }
                    .padding(12)
                }
                .task(id: file.id) {
                    info = nil
                    let url = file.url
                    let parsed = await Task.detached(priority: .utility) {
                        MetadataService.info(for: url)
                    }.value
                    // task(id:) 在文件切换时会取消旧任务;以此挡住迟到的旧结果覆盖新图信息
                    guard !Task.isCancelled else { return }
                    withAnimation(.easeIn(duration: 0.12)) { info = parsed }
                }
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "info.circle")
                        .font(.system(size: 26))
                        .foregroundStyle(.secondary)
                    Text("打开图片后显示信息")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .safeAreaInset(edge: .top) {
            HStack(spacing: 8) {
                Text("图片信息")
                    .font(.headline)
                Spacer()
                Button {
                    copyInfo()
                } label: {
                    Label("复制", systemImage: "doc.on.doc")
                        .font(.callout)
                }
                .controlSize(.small)
                .buttonStyle(.borderless)
                .disabled(info == nil)
                .help("复制全部信息")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            // 扁平:与面板同色纯底,不带材质厚度;仅靠底部细线与内容分界
            .background(ChromeTheme.fill(canvasBackground))
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(.separator.opacity(0.5))
                    .frame(height: 1)
            }
        }
        .background(ChromeTheme.fill(canvasBackground).ignoresSafeArea())
        .environment(\.colorScheme, ChromeTheme.colorScheme(for: canvasBackground))
    }

    private func sectionView(_ section: InfoSection) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(section.title)
                .font(.callout.weight(.semibold))
                .foregroundStyle(.secondary)
            ForEach(section.rows) { row in
                HStack(alignment: .top, spacing: 8) {
                    Text(row.label)
                        .foregroundStyle(.secondary)
                        .frame(width: 72, alignment: .leading)
                    Text(row.value)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .font(.caption)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(.quinary)
                // 面板底色和画布同色,卡片加一圈细描边才有层次
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.quaternary))
        )
    }

    private func copyInfo() {
        guard let info else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(info.summaryText, forType: .string)
    }
}
