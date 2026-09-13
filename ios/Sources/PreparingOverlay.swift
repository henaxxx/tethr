import SwiftUI

/// 接続直後の「カードを確認中」を全面に出す。
///
/// この間は ImageCaptureCore がカードを下調べしていて、設定変更も撮影通知も受け付けない
/// （カードの枚数に比例し、D300 で 1 件約 17 ミリ秒）。何もできない時間なので、
/// 固まって見えないよう画面全体で待っていることを伝える。
/// アイコンと同じ絞り羽根がゆっくり回りながら開閉し、終わると全開になって本来の画面が現れる。
struct PreparingOverlay: View {
    /// 準備が始まった時刻
    let since: Date?
    /// 前回このカメラで数えたカード内の件数。無ければ残り時間は出さない
    let count: Int?
    /// 準備が終わった時刻。ここから絞りを全開にして消える
    let reveal: Date?

    private static let perFile = 0.017
    private let amber = Color(red: 0.96, green: 0.66, blue: 0.26)

    var body: some View {
        TimelineView(.animation) { timeline in
            let now = timeline.date
            let elapsed = since.map { now.timeIntervalSince($0) } ?? 0
            let estimate = count.map { max(1, Double($0) * Self.perFile) }
            let progress = reveal != nil ? 1 : estimate.map { min(0.95, elapsed / $0) }

            VStack(spacing: 0) {
                Spacer()
                ApertureIris(time: now, reveal: reveal)
                    .frame(width: 148, height: 148)
                    .padding(.bottom, 34)

                Text("カードを確認中")
                    .font(.system(size: 18, weight: .semibold, design: .rounded))
                    .padding(.bottom, 6)

                Group {
                    if let count, let estimate {
                        let remaining = Int((estimate - elapsed).rounded(.up))
                        if remaining > 0 {
                            Text("\(count) 件・あと約 \(remaining) 秒")
                        } else {
                            Text("\(count) 件・もう少しで終わります")
                        }
                    } else {
                        Text("カメラの準備ができるまでお待ちください")
                    }
                }
                .font(.system(size: 13).monospacedDigit())
                .foregroundStyle(.secondary)
                .padding(.bottom, 22)

                FilmFrames(progress: progress, time: now, lit: amber)

                Spacer()

            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Color(uiColor: .systemBackground))
    }
}

/// フィルムのコマに見立てた進み具合。件数が分からないときは光が流れるだけにする
private struct FilmFrames: View {
    let progress: Double?
    let time: Date
    let lit: Color

    private let frames = 12

    var body: some View {
        let t = time.timeIntervalSinceReferenceDate
        HStack(spacing: 5) {
            ForEach(0..<frames, id: \.self) { i in
                RoundedRectangle(cornerRadius: 2.5)
                    .fill(lit.opacity(level(i, t)))
                    .background(RoundedRectangle(cornerRadius: 2.5).fill(Color(uiColor: .tertiarySystemFill)))
                    .frame(width: 11, height: 15)
            }
        }
    }

    private func level(_ i: Int, _ t: Double) -> Double {
        if let progress {
            let filled = progress * Double(frames)
            if Double(i) < filled.rounded(.down) { return 1 }
            if i == Int(filled) {
                // いま読んでいるコマはゆっくり明滅させる
                return 0.35 + 0.35 * (0.5 + 0.5 * sin(t * 5))
            }
            return 0
        }
        // 件数が分からない。光が左から右へ流れて、尾を引く
        let head = (t * 7).truncatingRemainder(dividingBy: Double(frames + 4))
        let d = head - Double(i)
        return d >= 0 && d < 4 ? 1 - d / 4 : 0
    }
}

/// アイコンと同じ 6 枚の絞り羽根。開閉しながらゆっくり回る
struct ApertureIris: View {
    let time: Date
    let reveal: Date?

    private static let blades = 6
    private static let twist = Double.pi / 7   // アイコンと同じひねり

    var body: some View {
        Canvas { ctx, size in
            let r = min(size.width, size.height) / 2
            let c = CGPoint(x: size.width / 2, y: size.height / 2)
            let t = time.timeIntervalSinceReferenceDate

            // 羽根の開き具合（開口部の半径 / 外径）。呼吸するように開閉する
            var opening = 0.34 + 0.12 * sin(t * 2 * .pi / 2.6)
            var fade = 1.0
            if let reveal {
                // 準備が終わった。シャッターが開くように全開まで広げて消す
                let p = min(1, max(0, time.timeIntervalSince(reveal) / 0.5))
                let eased = 1 - pow(1 - p, 3)
                opening = opening + (0.995 - opening) * eased
                fade = 1 - p * p
            }
            // 閉じるほど羽根が回り込む。実物の絞りと同じ動き
            let rotation = t * 0.35 + (0.46 - opening) * 1.4
            let inner = r * opening

            func pt(_ radius: Double, _ angle: Double) -> CGPoint {
                CGPoint(x: c.x + radius * cos(angle), y: c.y + radius * sin(angle))
            }

            ctx.opacity = fade
            // 外周の縁
            ctx.fill(Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)),
                     with: .color(Color(red: 0.11, green: 0.12, blue: 0.14)))

            let step = 2 * Double.pi / Double(Self.blades)
            for i in 0..<Self.blades {
                let a0 = Double(i) * step + .pi / 6 + rotation
                let a1 = a0 + step
                var blade = Path()
                blade.move(to: pt(r * 0.96, a0))
                blade.addArc(center: c, radius: r * 0.96, startAngle: .radians(a0), endAngle: .radians(a1), clockwise: false)
                blade.addLine(to: pt(inner, a1 - Self.twist))
                blade.addLine(to: pt(inner, a0 - Self.twist))
                blade.closeSubpath()

                // 羽根ごとに光の当たり方を変えて立体感を出す（アイコンと同じ配色）
                let k = Double(i) / Double(Self.blades - 1)
                let color = Color(red: (255 - 60 * k) / 255, green: (170 - 60 * k) / 255, blue: (70 - 30 * k) / 255)
                ctx.fill(blade, with: .color(color))
                ctx.stroke(blade, with: .color(Color(red: 0.08, green: 0.06, blue: 0.05).opacity(0.55)), lineWidth: 1.2)
            }

            // 開口部を暗く抜き、奥にわずかな反射を置く
            var hole = Path()
            for i in 0..<Self.blades {
                let p = pt(inner, Double(i) * step + .pi / 6 + rotation - Self.twist)
                i == 0 ? hole.move(to: p) : hole.addLine(to: p)
            }
            hole.closeSubpath()
            ctx.fill(hole, with: .color(Color(red: 0.05, green: 0.05, blue: 0.06)))
            ctx.fill(hole, with: .radialGradient(
                Gradient(colors: [Color(red: 0.35, green: 0.47, blue: 0.67).opacity(0.5), .clear]),
                center: CGPoint(x: c.x - inner * 0.3, y: c.y - inner * 0.35),
                startRadius: 0, endRadius: inner * 1.3))
        }
    }
}
