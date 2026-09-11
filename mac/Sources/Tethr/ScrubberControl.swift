import SwiftUI
import AppKit

/// スクラバーのポインタ操作を受け持つ NSView。
/// 連続的な横ドラッグ・ホイール・クリック位置を SwiftUI へ渡す。
private struct ScrubInteraction: NSViewRepresentable {
    let onDrag: (CGFloat) -> Void      // 前回からの相対移動量
    let onRelease: () -> Void
    let onStep: (Int) -> Void          // ホイール・矢印キーによる 1 段送り
    let onClick: (CGFloat) -> Void     // ビュー左端からの x 座標
    let onHover: (Bool) -> Void

    func makeNSView(context: Context) -> NSView {
        ScrubView(onDrag: onDrag, onRelease: onRelease, onStep: onStep,
                  onClick: onClick, onHover: onHover)
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let v = nsView as? ScrubView else { return }
        v.onDrag = onDrag
        v.onRelease = onRelease
        v.onStep = onStep
        v.onClick = onClick
        v.onHover = onHover
    }

    final class ScrubView: NSView {
        var onDrag: (CGFloat) -> Void
        var onRelease: () -> Void
        var onStep: (Int) -> Void
        var onClick: (CGFloat) -> Void
        var onHover: (Bool) -> Void

        private var lastX: CGFloat?
        private var travelled: CGFloat = 0
        private var scrollAccum: CGFloat = 0
        private weak var previousResponder: NSResponder?

        init(onDrag: @escaping (CGFloat) -> Void,
             onRelease: @escaping () -> Void,
             onStep: @escaping (Int) -> Void,
             onClick: @escaping (CGFloat) -> Void,
             onHover: @escaping (Bool) -> Void) {
            self.onDrag = onDrag
            self.onRelease = onRelease
            self.onStep = onStep
            self.onClick = onClick
            self.onHover = onHover
            super.init(frame: .zero)
        }
        required init?(coder: NSCoder) { fatalError() }

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override var acceptsFirstResponder: Bool { true }

        override func resetCursorRects() {
            addCursorRect(bounds, cursor: .resizeLeftRight)
        }

        // MARK: ホバーとキーボード

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            trackingAreas.forEach(removeTrackingArea)
            addTrackingArea(NSTrackingArea(
                rect: bounds,
                options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                owner: self))
        }

        /// カーソルが乗っている間だけキー入力を受け取る。
        /// 元のフォーカス位置は覚えておき、出るときに戻す。
        override func mouseEntered(with event: NSEvent) {
            previousResponder = window?.firstResponder
            window?.makeFirstResponder(self)
            onHover(true)
        }

        override func mouseExited(with event: NSEvent) {
            if window?.firstResponder === self {
                window?.makeFirstResponder(previousResponder)
            }
            previousResponder = nil
            onHover(false)
        }

        override func keyDown(with event: NSEvent) {
            switch event.keyCode {
            case 123, 125: onStep(-1)   // ← / ↓
            case 124, 126: onStep(1)    // → / ↑
            default: super.keyDown(with: event)
            }
        }

        override func scrollWheel(with event: NSEvent) {
            // 横スクロール優先。縦しか出ないマウスでも操作できるよう縦も拾う。
            let delta = abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY)
                ? -event.scrollingDeltaX
                : event.scrollingDeltaY
            scrollAccum += delta
            let threshold: CGFloat = event.hasPreciseScrollingDeltas ? 10 : 1
            while abs(scrollAccum) >= threshold {
                onStep(scrollAccum > 0 ? 1 : -1)
                scrollAccum -= (scrollAccum > 0 ? threshold : -threshold)
            }
        }

        override func mouseDown(with event: NSEvent) {
            lastX = convert(event.locationInWindow, from: nil).x
            travelled = 0
        }

        override func mouseDragged(with event: NSEvent) {
            let x = convert(event.locationInWindow, from: nil).x
            defer { lastX = x }
            guard let last = lastX else { return }
            let dx = x - last
            travelled += abs(dx)
            onDrag(dx)
        }

        override func mouseUp(with event: NSEvent) {
            let x = convert(event.locationInWindow, from: nil).x
            lastX = nil
            // ほとんど動いていなければクリックとして扱い、その位置の値へ飛ぶ
            if travelled < 3 {
                onClick(x)
            } else {
                onRelease()
            }
            travelled = 0
        }
    }
}

/// 値を横一列に並べ、中央のマーカーに合わせて選ぶ。
/// 前後の値が常に見えているので「あと 2 段」といった操作が目視でできる。
///
/// ドラッグ中はカメラへ書き込まず、指を離した時点で確定する。
/// 通過した値をいちいち書き込むと PTP の往復でつっかえるため。
struct ScrubberControl: View {
    let title: LocalizedStringKey
    let options: [String]
    let format: (String) -> String
    @Binding var selection: String
    var enabled: Bool = true
    /// カメラ側が値を決めていて変更できない状態（A の shutterspeed など）
    var locked: Bool = false

    @State private var dragOffset: CGFloat = 0
    @State private var hovered = false

    private let itemWidth: CGFloat = 58
    private let stripHeight: CGFloat = 34

    private var baseIndex: Int { options.firstIndex(of: selection) ?? 0 }

    /// ドラッグ量を織り込んだ、いま中央にある値の位置
    private var displayIndex: Int {
        guard !options.isEmpty else { return 0 }
        let shifted = CGFloat(baseIndex) - (dragOffset / itemWidth)
        return min(max(Int(shifted.rounded()), 0), options.count - 1)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(title)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                if locked {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 8))
                        .foregroundStyle(.tertiary)
                        .help("このモードではカメラが自動で決めます")
                }
                Spacer()
                Text(options.isEmpty ? "—" : format(options[displayIndex]))
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(enabled ? .primary : .tertiary)
            }

            GeometryReader { geo in
                ZStack {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color(nsColor: .controlBackgroundColor))
                        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.separator, lineWidth: 1))

                    strip(width: geo.size.width)
                        .mask(edgeFade)

                    // 中央マーカー
                    RoundedRectangle(cornerRadius: 4)
                        .strokeBorder(Color.accentColor.opacity(enabled ? (hovered ? 1 : 0.75) : 0.3),
                                      lineWidth: hovered ? 2 : 1.5)
                        .frame(width: itemWidth - 10, height: stripHeight - 8)
                        .animation(.easeOut(duration: 0.12), value: hovered)
                }
                .frame(width: geo.size.width, height: stripHeight)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(
                    enabled
                    ? ScrubInteraction(
                        onDrag: { drag($0) },
                        onRelease: { commit() },
                        onStep: { step($0) },
                        onClick: { jump(to: $0, width: geo.size.width) },
                        onHover: { hovered = $0 })
                    : nil
                )
            }
            .frame(height: stripHeight)
        }
        .opacity(enabled ? 1 : 0.5)
        .help("ドラッグ・ホイール・矢印キーで選択")
    }

    // MARK: 描画

    private func strip(width: CGFloat) -> some View {
        HStack(spacing: 0) {
            ForEach(Array(options.enumerated()), id: \.offset) { i, option in
                Text(format(option))
                    .font(.system(size: i == displayIndex ? 13 : 11,
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
        // ZStack は子を中央に置くため、そのままだと項目列の原点が
        // 左端ではなく (表示幅 - 全体幅) / 2 の位置になり、
        // 項目数が多いスクラバーほど大きくズレる。左寄せで原点を固定する。
        .frame(width: width, alignment: .leading)
        .offset(x: width / 2 - (CGFloat(baseIndex) * itemWidth + itemWidth / 2) + dragOffset)
        .animation(.easeOut(duration: 0.12), value: baseIndex)
    }

    private var edgeFade: some View {
        LinearGradient(
            stops: [
                .init(color: .clear, location: 0),
                .init(color: .black, location: 0.16),
                .init(color: .black, location: 0.84),
                .init(color: .clear, location: 1),
            ],
            startPoint: .leading, endPoint: .trailing
        )
    }

    // MARK: 操作

    private func drag(_ dx: CGFloat) {
        guard !options.isEmpty else { return }
        // 端を越えて滑っていかないよう、移動量そのものを範囲内に抑える
        let maxRight = CGFloat(baseIndex) * itemWidth
        let maxLeft = -CGFloat(options.count - 1 - baseIndex) * itemWidth
        dragOffset = min(max(dragOffset + dx, maxLeft), maxRight)
    }

    private func commit() {
        guard !options.isEmpty else { return }
        let target = displayIndex
        dragOffset = 0
        if options[target] != selection {
            selection = options[target]
        }
    }

    private func step(_ delta: Int) {
        guard !options.isEmpty else { return }
        let next = min(max(baseIndex + delta, 0), options.count - 1)
        guard next != baseIndex else { return }
        dragOffset = 0
        selection = options[next]
    }

    private func jump(to x: CGFloat, width: CGFloat) {
        guard !options.isEmpty else { return }
        // クリック位置が中央から何項目ぶんずれているか
        let delta = Int(((x - width / 2) / itemWidth).rounded())
        step(delta)
    }
}
