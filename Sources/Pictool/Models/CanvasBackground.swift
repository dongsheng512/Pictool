import AppKit

/// 画布背景偏好(存入 UserDefaults 的原始值为 rawValue)
enum CanvasBackground: String, CaseIterable, Identifiable {

    case dark
    case light

    static let storageKey = "canvasBackground"
    static let defaultValue = CanvasBackground.light

    var isDark: Bool { self == .dark }

    /// 旧版「棋盘格」收成白色
    static func normalizeStoredValue() {
        if UserDefaults.standard.string(forKey: storageKey) == "checkerboard" {
            UserDefaults.standard.set(CanvasBackground.light.rawValue, forKey: storageKey)
        }
    }

    var id: String { rawValue }

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

    func fill(_ dirtyRect: NSRect) {
        color.setFill()
        dirtyRect.fill()
    }
}
