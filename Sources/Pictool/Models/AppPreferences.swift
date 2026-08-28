import Foundation

/// 打开新图时的默认缩放
enum OpenZoomMode: String, CaseIterable, Identifiable {
    case fit
    case actualSize

    static let storageKey = "openZoomMode"
    static let defaultValue = OpenZoomMode.fit

    var id: String { rawValue }

    var label: String {
        switch self {
        case .fit: "适配窗口"
        case .actualSize: "实际大小"
        }
    }
}

/// 图片列表排序键
enum ImageSortKey: String, CaseIterable, Identifiable {
    case name
    case modified
    case captured
    case size

    static let storageKey = "imageSortKey"
    static let defaultValue = ImageSortKey.name

    var id: String { rawValue }

    var label: String {
        switch self {
        case .name: "文件名"
        case .modified: "修改时间"
        case .captured: "拍摄时间"
        case .size: "文件大小"
        }
    }
}

enum ImageSortDirection: String, CaseIterable, Identifiable {
    case ascending
    case descending

    static let storageKey = "imageSortDirection"
    static let defaultValue = ImageSortDirection.ascending

    var id: String { rawValue }

    var label: String {
        switch self {
        case .ascending: "升序"
        case .descending: "降序"
        }
    }
}

struct ImageSortPreference: Equatable, Sendable {
    var key: ImageSortKey
    var direction: ImageSortDirection

    static let `default` = ImageSortPreference(key: .name, direction: .ascending)

    static func load(from defaults: UserDefaults = .standard) -> ImageSortPreference {
        let key = ImageSortKey(rawValue: defaults.string(forKey: ImageSortKey.storageKey) ?? "")
            ?? ImageSortKey.defaultValue
        let direction = ImageSortDirection(rawValue: defaults.string(forKey: ImageSortDirection.storageKey) ?? "")
            ?? ImageSortDirection.defaultValue
        return ImageSortPreference(key: key, direction: direction)
    }
}

enum WrapNavigation {
    static let storageKey = "wrapImageNavigation"
    static let defaultValue = true
}

/// 侧栏正上方那一段(红绿灯所在列)的配色
enum SidebarTopStyle: String, CaseIterable, Identifiable {
    /// 与侧栏同色,整列通到窗口顶,和主区顶栏分开
    case followSidebar
    /// 与主区顶栏同色,通栏工具条
    case followChrome

    static let storageKey = "sidebarTopStyle"
    static let defaultValue = SidebarTopStyle.followSidebar

    var id: String { rawValue }

    var label: String {
        switch self {
        case .followSidebar: "跟随侧栏"
        case .followChrome: "与顶栏同色"
        }
    }
}

/// 切图下标换算(纯函数,单测覆盖循环/夹取)
enum ImageNavigation {
    /// 返回下一张下标;越界且不循环时返回 nil。单张循环时仍返回 0。
    static func nextIndex(current: Int, count: Int, delta: Int, wrap: Bool) -> Int? {
        guard count > 0 else { return nil }
        let base = current < 0 ? 0 : current
        let next = base + delta
        if wrap {
            return ((next % count) + count) % count
        }
        guard (0..<count).contains(next) else { return nil }
        return next
    }
}
