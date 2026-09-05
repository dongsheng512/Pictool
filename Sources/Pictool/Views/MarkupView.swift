import SwiftUI

/// 兼容入口:标记快捷键停在文字工具。实现见 `EditView`。
struct MarkupView: View {
    let file: ImageFile
    let initialQuarterTurns: Int

    var body: some View {
        EditView(file: file, initialQuarterTurns: initialQuarterTurns, initialTool: .text)
    }
}
