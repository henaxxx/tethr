import SwiftUI

/// カメラの露出計をそのまま可視化する。
/// 中央が適正。Nikon の慣習に合わせ、左が＋（露出過多）、右が−（露出不足）。
/// Canon とは左右が逆になる。
public struct LightMeterView: View {
    let value: Double?

    public init(value: Double?) {
        self.value = value
    }

    public var body: some View {
        let ev = max(-3, min(3, value ?? 0))
        HStack(spacing: 6) {
            Text("+").font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.dim)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    HStack(spacing: 0) {
                        ForEach(0..<13) { i in
                            Rectangle()
                                .fill(i == 6 ? Theme.dim : Theme.dimmer.opacity(i % 2 == 0 ? 1 : 0.6))
                                .frame(width: 1, height: i == 6 ? 14 : (i % 2 == 0 ? 9 : 5))
                            if i < 12 { Spacer(minLength: 0) }
                        }
                    }
                    .frame(height: 16)

                    if value != nil {
                        Capsule()
                            .fill(Theme.amber)
                            .frame(width: 3, height: 16)
                            .offset(x: (geo.size.width - 3) * ((3 - ev) / 6))
                            .animation(.easeOut(duration: 0.15), value: ev)
                    }
                }
                .frame(height: 16)
            }
            .frame(maxWidth: 170)
            .frame(height: 16)
            Text("−").font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.dim)
            Text(value.map { abs($0) < 0.05 ? "±0" : String(format: "%+.1f", $0) } ?? "—")
                .font(.system(size: 13, weight: .semibold, design: .rounded).monospacedDigit())
                .foregroundStyle(value.map { abs($0) < 0.2 } == true ? Theme.amber : Theme.text)
                .frame(width: 36, alignment: .trailing)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("露出計"))
        .accessibilityValue(Text(value.map { String(format: "%+.1f EV", $0) } ?? "—"))
    }
}
