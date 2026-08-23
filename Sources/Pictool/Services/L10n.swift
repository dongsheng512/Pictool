import Foundation

/// 极简双语支持:App 尚无 .lproj 本地化资源,按系统首选语言在运行时取词。
/// 覆盖范围:打开文件夹面板、打印选项页(其余界面文案暂为固定中文);
/// 后续接入 Localizable.strings 时可整体替换此文件。
enum L10n {

    /// 系统首选语言是否为中文(跟随用户系统设置的语言排序,含单 App 语言覆盖)
    static var isChinese: Bool {
        if let preferred = Locale.preferredLanguages.first {
            return preferred.hasPrefix("zh")
        }
        return Locale.autoupdatingCurrent.language.languageCode == .chinese
    }

    // MARK: 打开文件夹面板

    static var openFolderTitle: String {
        isChinese ? "打开图片文件夹" : "Open Image Folder"
    }

    static var openFolderMessage: String {
        isChinese ? "选择一个包含图片的文件夹" : "Choose a folder that contains images"
    }

}
