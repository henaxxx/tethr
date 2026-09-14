import SwiftUI
import TethrUI

/// 写真の上や下の段に置く、アイコンだけの丸いボタン。見た目は小さく、触れる範囲は 44pt 取る
struct IconButton: View {
    let systemName: String
    var tint: Color = Theme.text
    var filled = true
    let label: Text
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(tint)
                .frame(width: 36, height: 36)
                .modifier(OptionalGlass(enabled: filled))
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    private struct OptionalGlass: ViewModifier {
        let enabled: Bool
        func body(content: Content) -> some View {
            if enabled { content.glassCircle() } else { content }
        }
    }
}
