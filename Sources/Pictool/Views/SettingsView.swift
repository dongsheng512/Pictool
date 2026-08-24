import SwiftUI

/// 偏好设置窗口(⌘,)
struct SettingsView: View {

    @AppStorage(CanvasBackground.storageKey) private var canvasBackground = CanvasBackground.defaultValue.rawValue

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("画布背景")
                .font(.headline)
            Picker(selection: $canvasBackground) {
                ForEach(CanvasBackground.allCases) { option in
                    Text(option.label).tag(option.rawValue)
                }
            } label: {
                EmptyView()
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()
            Spacer(minLength: 0)
        }
        .padding(24)
        .frame(width: 280, height: 160, alignment: .topLeading)
    }
}
