import SwiftUI

/// 偏好设置窗口(⌘,)
struct SettingsView: View {

    @AppStorage(CanvasBackground.storageKey) private var canvasBackground = CanvasBackground.defaultValue
    @AppStorage(SidebarTopStyle.storageKey) private var sidebarTopStyle = SidebarTopStyle.defaultValue
    @AppStorage(OpenZoomMode.storageKey) private var openZoomMode = OpenZoomMode.defaultValue
    @AppStorage(WrapNavigation.storageKey) private var wrapNavigation = WrapNavigation.defaultValue
    @AppStorage(ImageSortKey.storageKey) private var sortKey = ImageSortKey.defaultValue
    @AppStorage(ImageSortDirection.storageKey) private var sortDirection = ImageSortDirection.defaultValue

    var body: some View {
        Form {
            Section("外观") {
                Picker("画布背景", selection: $canvasBackground) {
                    ForEach(CanvasBackground.allCases) { option in
                        Text(option.label).tag(option)
                    }
                }
                .pickerStyle(.radioGroup)
                Picker("侧栏顶栏", selection: $sidebarTopStyle) {
                    ForEach(SidebarTopStyle.allCases) { option in
                        Text(option.label).tag(option)
                    }
                }
                .pickerStyle(.radioGroup)
            }
            Section("浏览") {
                Picker("打开时缩放", selection: $openZoomMode) {
                    ForEach(OpenZoomMode.allCases) { option in
                        Text(option.label).tag(option)
                    }
                }
                .pickerStyle(.radioGroup)
                Toggle("到首尾后循环", isOn: $wrapNavigation)
                Picker("排序", selection: $sortKey) {
                    ForEach(ImageSortKey.allCases) { option in
                        Text(option.label).tag(option)
                    }
                }
                Picker("顺序", selection: $sortDirection) {
                    ForEach(ImageSortDirection.allCases) { option in
                        Text(option.label).tag(option)
                    }
                }
                .pickerStyle(.radioGroup)
            }
        }
        .formStyle(.grouped)
        .frame(width: 360)
        .onAppear { CanvasBackground.normalizeStoredValue() }
    }
}
