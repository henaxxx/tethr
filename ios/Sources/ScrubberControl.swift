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
    /// 端に当たっている。当たった瞬間に 1 度だけ手応えを返す
    @State private var atEdge = false
    /// 指を離して選んだ段。カメラが応えるまでここに留める
    @State private var pendingIndex: Int?
    /// 返事を待つ間に次の操作が来たら、古い返事で表示を戻さないための番号
    @State private var generation = 0

    private let itemWidth: CGFloat = 62
    private let stripHeight: CGFloat = 44
    /// 名前が載る左端の幅。値はこの下を通るあいだ消える
    private let labelWidth: CGFloat = 80

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

    /// 値は帯の中央の枠で読み、名前は左端に重ねる。
    ///
    /// 帯は行の幅いっぱいに取り、枠を行の中央（＝画面の中央、シャッターの真上）に置く。
    /// 名前の列を別に取ると、そのぶん枠が右へずれていた
    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                strip(width: geo.size.width)
                    .mask(edgeFade(width: geo.size.width))

                RoundedRectangle(cornerRadius: 7)
                    .strokeBorder(enabled ? Theme.amber : Theme.dimmer, lineWidth: 1.5)
                    .frame(width: itemWidth - 6, height: stripHeight - 10)
                    .frame(maxWidth: .infinity)
                    // 書き込みの返事を待っている間は枠を少し沈ませ、送ったことを伝える
                    .opacity(pendingIndex == nil ? 1 : 0.5)
                    .animation(.easeInOut(duration: 0.2), value: pendingIndex == nil)

                Text(title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(enabled ? Theme.dim : Theme.dimmer)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .frame(width: labelWidth - 14, alignment: .leading)
                    .padding(.leading, 12)
            }
            .frame(width: geo.size.width, height: stripHeight)
            .clipped()
            .contentShape(Rectangle())
            .gesture(scrub)
        }
        .frame(height: stripHeight)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(title))
        .accessibilityValue(Text(options.isEmpty ? "—" : options[displayIndex]))
        .accessibilityAdjustableAction { direction in
            guard enabled, !options.isEmpty else { return }
            let target = baseIndex + (direction == .increment ? 1 : -1)
            guard options.indices.contains(target) else { return }
            commit(target)
        }
        .disabled(!enabled)
        // 段をまたぐたびに軽く手応えを返す。カメラ側の変化（A モードで自動に変わる等）では鳴らさない
        .onChange(of: displayIndex) { _, _ in
            if dragging { Haptics.select() }
        }
    }

    private func strip(width: CGFloat) -> some View {
        HStack(spacing: 0) {
            ForEach(Array(options.enumerated()), id: \.offset) { i, option in
                Text(option)
                    .font(.system(size: i == displayIndex ? 16 : 13,
                                  weight: i == displayIndex ? .semibold : .regular,
                                  design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(i != displayIndex ? Theme.dim : enabled ? Theme.amber : Theme.dim)
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

    /// 左は名前の下で消し、右は端でぼかす
    private func edgeFade(width: CGFloat) -> some View {
        let w = max(width, labelWidth + 80)
        return LinearGradient(
            stops: [
                .init(color: .clear, location: 0),
                .init(color: .clear, location: (labelWidth - 6) / w),
                .init(color: .black, location: (labelWidth + 34) / w),
                .init(color: .black, location: 1 - 70 / w),
                .init(color: .clear, location: 1),
            ],
            startPoint: .leading, endPoint: .trailing
        )
    }

    private var scrub: some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                guard !options.isEmpty else { return }
                if !dragging { Haptics.prepareForDrag() }
                dragging = true
                // 端を越えて滑らないよう、移動量そのものを制限する
                let maxRight = CGFloat(baseIndex) * itemWidth
                let maxLeft = -CGFloat(options.count - 1 - baseIndex) * itemWidth
                let raw = value.translation.width
                dragOffset = min(max(raw, maxLeft), maxRight)
                // 端の段を越えて引っ張った瞬間。端の段に来たときの selection とは別に、行き止まりを伝える
                let pastEdge = raw > maxRight + itemWidth / 2 || raw < maxLeft - itemWidth / 2
                if pastEdge && !atEdge { Haptics.edge() }
                atEdge = pastEdge
            }
            .onEnded { _ in
                dragging = false
                atEdge = false
                let target = displayIndex
                // 指を離した位置から、選んだ段の中央へなめらかに寄せる。返事を待たずにそこへ留める
                if target == selectedIndex {
                    withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) {
                        pendingIndex = nil
                        dragOffset = 0
                    }
                } else {
                    commit(target)
                }
            }
    }

    /// 選んだ段を書き込む。返事が来たらカメラの値に合わせる（通っていれば動かず、弾かれていれば元へ戻る）
    private func commit(_ target: Int) {
        withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) {
            pendingIndex = target
            dragOffset = 0
        }
        generation += 1
        let mine = generation
        Task { @MainActor in
            let accepted = await onSelect(target)
            // 返事を待つ間に次の操作があったら、そちらに任せる
            guard mine == generation else { return }
            withAnimation(.spring(response: 0.32, dampingFraction: 0.9)) {
                pendingIndex = nil
            }
            if !accepted { Haptics.warning() }
        }
    }
}
