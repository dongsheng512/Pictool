import AppKit

/// 画布背景偏好(存入 UserDefaults 的原始值为 rawValue)
enum CanvasBackground: String, CaseIterable, Identifiable {

    case dark
    case light

    static let storageKey = "canvasBackground"
    static let defaultValue = CanvasBackground.dark

    var id: String { rawValue }

    /// 深色沿用原画布底色(white 0.10),浅色为纯白
    var color: NSColor {
        switch self {
        case .dark: NSColor(white: 0.10, alpha: 1)
        // 柔和米白 #FAFAFB，避免纯白与侧栏灰的生硬对比
        case .light: NSColor(red: 0.980, green: 0.980, blue: 0.984, alpha: 1)
        }
    }

    var label: String {
        switch self {
        case .dark: "黑色"
        case .light: "白色"
        }
    }
}
