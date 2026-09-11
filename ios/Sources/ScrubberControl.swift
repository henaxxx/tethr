import SwiftUI

/// 値を横一列に並べ、中央のマーカーに合わせて選ぶ。
/// 前後の値が常に見えるので、「あと2段」といった操作が目視でできる。
///
/// ドラッグ中はカメラへ書き込まず、指を離した時点で確定する。
/// 通過した値をいちいち書き込むと PTP の往復でつっかえるため。
struct ScrubberControl: View {
    let title: String
    let options: [String]
    let selectedIndex: Int
    var enabled: Bool = true
    let onSelect: (Int) -> Void

    @State private var dragOffset: CGFloat = 0

    private let itemWidth: CGFloat = 76
    private let stripHeight: CGFloat = 44

    /// ドラッグ量を織り込んだ、いま中央にある位置
    private var displayIndex: Int {
        guard !options.isEmpty else { return 0 }
        let shifted = CGFloat(selectedIndex) - (dragOffset / itemWidth)
        return min(max(Int(shifted.rounded()), 0), options.count - 1)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(title)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(options.isEmpty ? "—" : options[displayIndex])
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(enabled ? .primary : .tertiary)
            }

            GeometryReader { geo in
                ZStack {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color(uiColor: .secondarySystemBackground))

                    strip(width: geo.size.width)
                        .mask(edgeFade)

                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(Color.accentColor.opacity(enabled ? 0.9 : 0.3), lineWidth: 2)
                        .frame(width: itemWidth - 12, height: stripHeight - 10)
                }
                .frame(width: geo.size.width, height: stripHeight)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .contentShape(Rectangle())
                .gesture(scrub)
            }
            .frame(height: stripHeight)
        }
        .opacity(enabled ? 1 : 0.45)
        .disabled(!enabled)
    }

    private func strip(width: CGFloat) -> some View {
        HStack(spacing: 0) {
            ForEach(Array(options.enumerated()), id: \.offset) { i, option in
                Text(option)
                    .font(.system(size: i == displayIndex ? 16 : 13,
                                  weight: i == displayIndex ? .semibold : .regular,
                                  design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(i == displayIndex ? AnyShapeStyle(Color.accentColor)
                                                       : AnyShapeStyle(.secondary))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .frame(width: itemWidth)
            }
        }
        // 左寄せで原点を固定してから動かす。
        // 中央揃えのままだと項目数に応じてズレが出る。
        .frame(width: width, alignment: .leading)
        .offset(x: width / 2 - (CGFloat(selectedIndex) * itemWidth + itemWidth / 2) + dragOffset)
        .animation(.easeOut(duration: 0.12), value: selectedIndex)
    }

    private var edgeFade: some View {
        LinearGradient(
            stops: [
                .init(color: .clear, location: 0),
                .init(color: .black, location: 0.14),
                .init(color: .black, location: 0.86),
                .init(color: .clear, location: 1),
            ],
            startPoint: .leading, endPoint: .trailing
        )
    }

    private var scrub: some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                guard !options.isEmpty else { return }
                // 端を越えて滑らないよう、移動量そのものを制限する
                let maxRight = CGFloat(selectedIndex) * itemWidth
                let maxLeft = -CGFloat(options.count - 1 - selectedIndex) * itemWidth
                dragOffset = min(max(value.translation.width, maxLeft), maxRight)
            }
            .onEnded { _ in
                let target = displayIndex
                dragOffset = 0
                if target != selectedIndex { onSelect(target) }
            }
    }
}
