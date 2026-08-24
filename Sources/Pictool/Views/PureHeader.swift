import SwiftUI
import AppKit

/// 纯 SwiftUI 顶部栏：32pt，承载全部功能按钮，样式完全可定制。
/// 与系统标题栏解耦（hiddenTitleBar + WindowChrome），高度/背景/圆角均可改。
struct PureHeader: View {

    @Environment(FolderStore.self) private var store
    /// 侧栏可见时的宽度，用于让顶栏左段与侧栏材质无缝衔接（原生 Finder 效果）
    var sidebarWidth: CGFloat? = nil
    var sidebarVisible: Bool = false

    var body: some View {
        HStack(spacing: 5) {
            WindowControls()
            HeaderButton("sidebar.leading", help: "显示/隐藏侧栏 (⌃⌘S)") {
                store.toggleSidebar()
            }

            Spacer().frame(width: 8)
            Text("PureView")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.primary)

            Spacer()

            HeaderButton("folder.badge.plus", help: "打开图片文件夹 (⌘O)") {
                store.openFolderPanel()
            }

            HeaderDivider()

            HeaderButton("chevron.left", help: "上一张 (←)",
                         disabled: store.images.isEmpty) { store.step(-1) }
            HeaderButton("chevron.right", help: "下一张 (→)",
                         disabled: store.images.isEmpty) { store.step(1) }

            HeaderDivider()

            HeaderButton("minus.magnifyingglass", help: "缩小 (⌘-)",
                         disabled: store.currentImage == nil) { store.requestZoom(.zoomOut) }
            HeaderButton("plus.magnifyingglass", help: "放大 (⌘=)",
                         disabled: store.currentImage == nil) { store.requestZoom(.zoomIn) }

            HeaderDivider()

            HeaderButton("rotate.right", help: "顺时针旋转 90°",
                         disabled: store.currentImage == nil) { store.requestRotate() }
            HeaderButton("crop", help: "裁切 (C)",
                         disabled: store.currentImage == nil) { store.requestCrop() }
            HeaderButton("printer", help: "打印 (⌘P)",
                         disabled: store.currentImage == nil) { store.requestPrint() }
            HeaderButton("info.circle", help: "图片信息 (I)") {
                store.showInspector.toggle()
            }

            HeaderDivider()

            HeaderButton(
                store.isImmersive ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right",
                help: store.isImmersive ? "退出只看图 (Esc / F)" : "只看图,隐藏所有界面 (F)",
                disabled: store.currentImage == nil && !store.isImmersive
            ) { store.toggleImmersive() }
        }
        .padding(.horizontal, 12)
        .frame(height: 32)
        .frame(maxWidth: .infinity)
        // 可定制：背景材质、圆角、阴影都在此改
        .background {
            // 分段磨砂：左侧与侧栏同色，右侧与主区同色；两段直接相邻无间隙、无渐变块，靠色差本身区分
            // 已把两侧白度拉近（左 0.30 / 右 0.16）让竖向硬线对比从 17 降至 ~6，肉眼几乎看不见
            Group {
                if sidebarVisible, let w = sidebarWidth {
                    HStack(spacing: 0) {
                        ZStack {
                            SidebarMaterial()
                            Color.white.opacity(0.30)
                        }
                        .frame(width: w)
                        ZStack {
                            HeaderMaterial()
                            Color.white.opacity(0.16)
                        }
                    }
                } else {
                    ZStack {
                        HeaderMaterial()
                        Color.white.opacity(0.16)
                    }
                }
            }
        }        .background {
            // 自定义拖拽区：空白处拖动窗口，双击缩放；按钮区域不受影响
            Color.clear
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0, coordinateSpace: .global)
                        .onChanged { _ in
                            if let window = NSApp.keyWindow ?? NSApp.mainWindow,
                               let event = NSApp.currentEvent {
                                window.performDrag(with: event)
                            }
                        }
                )
                .onTapGesture(count: 2) { NSApp.keyWindow?.zoom(nil) }
        }

    }
}

private struct HeaderButton: View {
    let systemImage: String
    let help: String
    var disabled = false
    let action: () -> Void

    @State private var hovering = false

    init(_ systemImage: String, help: String, disabled: Bool = false, action: @escaping () -> Void) {
        self.systemImage = systemImage
        self.help = help
        self.disabled = disabled
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 12))
                .frame(width: 24, height: 20)
                .background(
                    hovering && !disabled ? Color.primary.opacity(0.08) : .clear,
                    in: RoundedRectangle(cornerRadius: 4)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled ? 0.35 : 1)
        .help(help)
        .onHover { hovering = $0 }
    }
}

private struct HeaderDivider: View {
    var body: some View { Divider().frame(height: 13) }
}

private struct WindowControls: View {
    @Environment(\.controlActiveState) private var active
    @Environment(\.dismiss) private var dismiss
    @State private var hovering = false
    private var window: NSWindow? {
        NSApp.keyWindow ?? NSApp.mainWindow ?? NSApp.windows.first(where: \.isVisible)
    }
    private var isKey: Bool { active == .key }
    var body: some View {
        HStack(spacing: 8) {
            Button {
                if let w = window {
                    w.close()
                    DispatchQueue.main.async {
                        if NSApp.windows.filter(\.isVisible).isEmpty { NSApp.terminate(nil) }
                    }
                } else {
                    dismiss()
                    NSApp.terminate(nil)
                }
            } label: {
                ZStack {
                    Circle().fill(isKey ? Color(red: 0.98, green: 0.37, blue: 0.33) : Color.gray.opacity(0.32))
                    Circle().stroke(Color.black.opacity(isKey ? 0.12 : 0.08), lineWidth: 0.5)
                    if hovering && isKey {
                        Image(systemName: "xmark")
                            .font(.system(size: 7, weight: .bold))
                            .foregroundStyle(Color.black.opacity(0.62))
                    }
                }
                .frame(width: 12, height: 12)
            }
            .buttonStyle(.plain)
            .help("关闭")
            Button {
                window?.miniaturize(nil)
            } label: {
                ZStack {
                    Circle().fill(isKey ? Color(red: 0.99, green: 0.76, blue: 0.20) : Color.gray.opacity(0.32))
                    Circle().stroke(Color.black.opacity(isKey ? 0.12 : 0.08), lineWidth: 0.5)
                    if hovering && isKey {
                        Image(systemName: "minus")
                            .font(.system(size: 7, weight: .bold))
                            .foregroundStyle(Color.black.opacity(0.62))
                    }
                }
                .frame(width: 12, height: 12)
            }
            .buttonStyle(.plain)
            .help("最小化")
            Button {
                window?.zoom(nil)
            } label: {
                ZStack {
                    Circle().fill(isKey ? Color(red: 0.18, green: 0.78, blue: 0.26) : Color.gray.opacity(0.32))
                    Circle().stroke(Color.black.opacity(isKey ? 0.12 : 0.08), lineWidth: 0.5)
                    if hovering && isKey {
                        Image(systemName: "arrow.up.left.and.arrow.down.right")
                            .font(.system(size: 6.5, weight: .bold))
                            .foregroundStyle(Color.black.opacity(0.62))
                    }
                }
                .frame(width: 12, height: 12)
            }
            .buttonStyle(.plain)
            .help("缩放")
        }
        .onHover { hovering = $0 }
    }
}
