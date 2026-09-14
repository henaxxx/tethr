import ActivityKit
import Foundation

/// ダイナミックアイランドとロック画面に出す、カメラとのつながり。アプリとウィジェット拡張の両方に入れる。
///
/// 表示を書き換えられるのはアプリが動いている間だけ（サーバーから送る仕組みは持たない）。
/// そのため、続いている作業がある間（接続の準備、カードの読み込み、背面で接続を保っている間）だけ出す
struct TethrActivityAttributes: ActivityAttributes {

    struct ContentState: Codable, Hashable {
        enum Phase: String, Codable, Hashable {
            /// セッションを開いたが、カードの下調べが終わるまで命令が通らない
            case preparing
            /// カードの一覧を読み込んでいる
            case loading
            /// つながっていて撮れる
            case connected
            /// 背面に回ったので接続を休ませた。アプリに戻ると続きから
            case paused
            /// 選んだカットを写真アプリへ取り込んでいる（loaded / expected が枚数）
            case importing
        }

        var phase: Phase
        /// 待ち始めた時刻。準備中は経過時間を数える
        var since: Date
        /// 届いたファイルの数と、接続時に数えたカード内のオブジェクト数
        var loaded: Int = 0
        var expected: Int?
        /// つないでから届いたカット
        var shots: Int = 0
        var lastShot: String?
        /// カメラの電池（%）
        var battery: Int?
        /// 背面で接続を保つ期限。過ぎると休ませる
        var keepUntil: Date?

        /// 読み込みの進み具合（0〜1）。分母が分からなければ nil
        var fraction: Double? {
            guard let expected, expected > 0 else { return nil }
            return min(1, Double(loaded) / Double(expected))
        }
    }

    var cameraName: String
}
