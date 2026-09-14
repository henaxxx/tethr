import UIKit
import UIKit.UIGestureRecognizerSubclass

/// 利用者が最後にアプリやカメラを操作した時刻。
///
/// 放置されたライブビューを止めるのに使う。画面のどこに触れても更新し、
/// 撮影中や本体のダイヤル操作（設定の変化が届いたとき）も操作として数える
@MainActor
enum Interaction {
    private(set) static var last = Date()

    static func touch() { last = Date() }

    static var idleSeconds: TimeInterval { Date().timeIntervalSince(last) }

    /// 開いている窓すべてに、触れたことだけを記録する認識器を付ける。ほかの操作の邪魔はしない
    static func installOnWindows() {
        let windows = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
        for window in windows where !(window.gestureRecognizers ?? []).contains(where: { $0 is TouchSpy }) {
            window.addGestureRecognizer(TouchSpy())
        }
    }
}

/// 指が触れた瞬間に時刻を残し、すぐに降りる。ボタンやスクロールには何も伝えない
private final class TouchSpy: UIGestureRecognizer {
    init() {
        super.init(target: nil, action: nil)
        cancelsTouchesInView = false
        delaysTouchesBegan = false
        delaysTouchesEnded = false
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        Interaction.touch()
        state = .failed
    }
}
