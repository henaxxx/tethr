import SwiftUI

/// 値を横一列に並べ、中央のマーカーに合わせて選ぶ。
/// 前後の値が常に見えるので、「あと2段」といった操作が目視でできる。
///
/// ドラッグ中はカメラへ書き込まず、指を離した時点で確定する。
/// 通過した値をいちいち書き込むと PTP の往復でつっかえるため。
///
/// 書き込みには PTP の往復ぶん時間がかかる。以前は指を離した瞬間に元の値へ戻り、
/// カメラの返事が来てから選んだ値へ動いていた。いまは選んだ段へそのまま寄せて留め、
/// 返事が来たらカメラの値に合わせる（通っていれば動かず、弾かれていれば元へ戻る）。
struct ScrubberControl: View {
    let title: String
    let options: [String]
    let selectedIndex: Int
    var enabled: Bool = true
    /// 選んだ段を書き込む。通ったかどうかを返す
    let onSelect: (Int) async -> Bool

    @State private var dragOffset: CGFloat = 0
    @State private var dragging = false
    /// 指を離して選んだ段。カメラが応えるまでここに留める
    @State private var pendingIndex: Int?
    /// 返事を待つ間に次の操作が来たら、古い返事で表示を戻さないための番号
    @State private var generation = 0

    private let itemWidth: CGFloat = 76
    private let stripHeight: CGFloat = 44

    /// 表示の基準にする段。返事待ちなら選んだ段、そうでなければカメラの値
    private var baseIndex: Int {
        guard !options.isEmpty else { return 0 }
        return min(max(pendingIndex ?? selectedIndex, 0), options.count - 1)
    }

    /// ドラッグ量を織り込んだ、いま中央にある位置
    private var displayIndex: Int {
        guard !options.isEmpty else { return 0 }
        let shifted = CGFloat(baseIndex) - (dragOffset / itemWidth)
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
                    .contentTransition(.numericText())
                    .animation(.snappy(duration: 0.18), value: displayIndex)
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
                        // 書き込みの返事を待っている間は枠を少し沈ませ、送ったことを伝える
                        .opacity(pendingIndex == nil ? 1 : 0.55)
                        .animation(.easeInOut(duration: 0.2), value: pendingIndex == nil)
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
        // 段をまたぐたびに軽く手応えを返す。カメラ側の変化（A モードで自動に変わる等）では鳴らさない
        .sensoryFeedback(.selection, trigger: displayIndex) { _, _ in dragging }
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
        .offset(x: width / 2 - (CGFloat(baseIndex) * itemWidth + itemWidth / 2) + dragOffset)
        // 本体のダイヤルを回した等、カメラ側で値が変わったときもなめらかに動かす
        .animation(.spring(response: 0.3, dampingFraction: 0.88), value: baseIndex)
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
                dragging = true
                // 端を越えて滑らないよう、移動量そのものを制限する
                let maxRight = CGFloat(baseIndex) * itemWidth
                let maxLeft = -CGFloat(options.count - 1 - baseIndex) * itemWidth
                dragOffset = min(max(value.translation.width, maxLeft), maxRight)
            }
            .onEnded { _ in
                dragging = false
                let target = displayIndex
                let current = selectedIndex
                // 指を離した位置から、選んだ段の中央へなめらかに寄せる。返事を待たずにそこへ留める
                withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) {
                    pendingIndex = target == current ? nil : target
                    dragOffset = 0
                }
                guard target != current else { return }
                generation += 1
                let mine = generation
                Task { @MainActor in
                    let accepted = await onSelect(target)
                    // 返事を待つ間に次の操作があったら、そちらに任せる
                    guard mine == generation else { return }
                    // カメラの値に合わせる。通っていれば位置は変わらず、弾かれていれば元へ戻る
                    withAnimation(.spring(response: 0.32, dampingFraction: 0.9)) {
                        pendingIndex = nil
                    }
                    if !accepted {
                        UINotificationFeedbackGenerator().notificationOccurred(.warning)
                    }
                }
            }
    }
}
