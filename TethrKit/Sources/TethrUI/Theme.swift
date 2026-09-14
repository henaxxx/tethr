import SwiftUI

/// 画面全体の色。サイトとアイコンに合わせ、暗いグレーに絞り羽根の琥珀色を 1 色だけ置く。
///
/// 背景をシステムのライト・ダークに任せないのは、写真の明るさの見え方が周りの色で変わるため。
/// 暗く中立な地の上で見るのが、現像ソフトやカメラの背面液晶と同じ条件になる。iOS 版と Mac 版で同じ色を使う
public enum Theme {
    /// 画面の地。写真の周りもこの色にして、余白が帯に見えないようにする
    public static let background = Color(red: 0.051, green: 0.051, blue: 0.059)     // #0D0D0F
    /// スクラバーの溝やボタンの地
    public static let surface = Color(red: 0.086, green: 0.086, blue: 0.102)         // #16161A
    public static let surfaceRaised = Color(red: 0.114, green: 0.114, blue: 0.133)   // #1D1D22

    public static let text = Color(red: 0.918, green: 0.906, blue: 0.886)            // #EAE7E2
    public static let dim = Color(red: 0.569, green: 0.553, blue: 0.529)             // #918D87
    public static let dimmer = Color(red: 0.388, green: 0.376, blue: 0.361)          // #63605C

    public static let amber = Color(red: 0.847, green: 0.639, blue: 0.255)           // #D8A341
    /// 琥珀の上に載せる文字
    public static let onAmber = Color(red: 0.165, green: 0.114, blue: 0.024)         // #2A1D06

    public static let danger = Color(red: 0.898, green: 0.357, blue: 0.318)
    public static let live = Color(red: 0.918, green: 0.263, blue: 0.227)
}

/// シャッター。白い輪の中に白い円。
///
/// 押している間は中の円が縮む。撮影中（AF から書き込みの受け付けまで）は外側の輪が細い弧になって回り、
/// 撮り終えると弧が一周を閉じて元の輪に戻る。待ち時間を別のぐるぐるで出さず、ボタンそのものに持たせる
public struct ShutterButton: View {
    let size: CGFloat
    let busy: Bool
    let enabled: Bool
    let action: () -> Void

    public init(size: CGFloat = 68, busy: Bool, enabled: Bool, action: @escaping () -> Void) {
        self.size = size
        self.busy = busy
        self.enabled = enabled
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            EmptyView()
        }
        .buttonStyle(ShutterStyle(size: size, busy: busy))
        .disabled(!enabled || busy)
        .opacity(enabled || busy ? 1 : 0.35)
        .accessibilityLabel(Text("シャッター"))
        .accessibilityValue(Text(busy ? "撮影中" : ""))
    }

    private struct ShutterStyle: ButtonStyle {
        let size: CGFloat
        let busy: Bool

        func makeBody(configuration: Configuration) -> some View {
            ShutterFace(size: size, busy: busy, pressed: configuration.isPressed)
        }
    }
}

private struct ShutterFace: View {
    let size: CGFloat
    let busy: Bool
    let pressed: Bool

    /// 回る弧の長さ（輪に対する割合）。撮り終えると 1 まで伸びて輪を閉じる
    @State private var arc: CGFloat = 0
    /// 弧を出しているか。閉じ終えたら消して、元の輪だけに戻す
    @State private var arcVisible = false
    @State private var spinStart = Date()

    private let lineWidth: CGFloat = 3

    var body: some View {
        ZStack {
            // 元の輪。撮影中は薄く残して、弧が走る溝にする
            Circle()
                .strokeBorder(Theme.text.opacity(arcVisible ? 0.22 : 1), lineWidth: lineWidth)

            if arcVisible {
                TimelineView(.animation(paused: !busy)) { timeline in
                    let turns = timeline.date.timeIntervalSince(spinStart) / 0.9
                    Circle()
                        .inset(by: lineWidth / 2)
                        .trim(from: 0, to: arc)
                        .stroke(Theme.text, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                        .rotationEffect(.degrees(turns * 360 - 90))
                }
            }

            Circle()
                .fill(Theme.text)
                .padding(7)
                .scaleEffect(busy ? 0.84 : pressed ? 0.88 : 1)
                .opacity(busy ? 0.8 : 1)
        }
        .frame(width: size, height: size)
        .contentShape(Circle())
        .animation(.easeOut(duration: 0.12), value: pressed)
        .animation(.spring(response: 0.35, dampingFraction: 0.7), value: busy)
        .onChange(of: busy) { _, busy in
            if busy {
                spinStart = Date()
                arcVisible = true
                arc = 0
                withAnimation(.easeOut(duration: 0.25)) { arc = 0.28 }
            } else if arcVisible {
                withAnimation(.easeInOut(duration: 0.28)) {
                    arc = 1
                } completion: {
                    withAnimation(.easeOut(duration: 0.2)) { arcVisible = false }
                    arc = 0
                }
            }
        }
    }
}

public extension View {
    /// 丸いボタンの地。iOS 26・macOS 26 では Liquid Glass、それより前は一段明るい地の円
    @ViewBuilder
    func glassCircle(tint: Color? = nil) -> some View {
        if #available(iOS 26.0, macOS 26.0, *) {
            glassEffect(tint.map { Glass.regular.tint($0).interactive() } ?? Glass.regular.interactive(), in: Circle())
        } else {
            background(tint ?? Theme.surfaceRaised, in: Circle())
        }
    }

    /// 横長のボタンの地。丸いボタンと同じガラスにする。`active` が偽なら地を消す（文字だけ残す）
    @ViewBuilder
    func glassCapsule(tint: Color? = nil, active: Bool = true) -> some View {
        if #available(iOS 26.0, macOS 26.0, *) {
            let glass = tint.map { Glass.regular.tint($0).interactive() } ?? Glass.regular.interactive()
            glassEffect(active ? glass : .identity, in: Capsule())
        } else {
            background(active ? (tint ?? Theme.surfaceRaised) : .clear, in: Capsule())
        }
    }
}
