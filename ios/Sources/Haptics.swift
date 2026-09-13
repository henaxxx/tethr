import UIKit

/// 触覚フィードバックの語彙。場面ごとに強さを決めておき、画面のあちこちから同じものを呼ぶ。
///
/// - 段を選ぶ（スクラバー、撮影モード、WB、テザー/カード、コマの選択、全画面の送り） … selection
/// - スクラバーの端に当たった … 硬く弱い 1 打
/// - シャッター … 硬く強い 1 打
/// - テザーにカットが届いた … 柔らかい 1 打（ポケットの中でも撮れたと分かる）
/// - 機能の入り切り（ライブビュー、接続・接続解除） … 中くらいの 1 打
/// - 済んだ（操作できるようになった、ライブビューが映った、取り込んだ、Mac へ送った） … success
/// - 弾かれた（設定の変更を断られた） … warning
/// - 失敗（エラーを出した） … error
///
/// 設定の変更を断られると warning と同時にエラー表示も出るので、通知系は短い間に重ねて鳴らさない
@MainActor
enum Haptics {
    private static let selection = UISelectionFeedbackGenerator()
    private static let rigid = UIImpactFeedbackGenerator(style: .rigid)
    private static let soft = UIImpactFeedbackGenerator(style: .soft)
    private static let medium = UIImpactFeedbackGenerator(style: .medium)
    private static let notification = UINotificationFeedbackGenerator()
    private static var lastNotification = Date.distantPast
    private static var lastShot = Date.distantPast

    /// 指が触れた時点で呼ぶ。最初の 1 打が遅れないように、振動子を起こしておく
    static func prepareForDrag() {
        selection.prepare()
        rigid.prepare()
    }

    static func select() {
        selection.selectionChanged()
        selection.prepare()
    }

    static func edge() {
        rigid.impactOccurred(intensity: 0.6)
    }

    static func shutter() {
        rigid.impactOccurred(intensity: 1.0)
    }

    /// 連写で続けて届いても、ブルブルと繋がらないように間引く
    static func shotArrived() {
        guard Date().timeIntervalSince(lastShot) > 0.3 else { return }
        lastShot = Date()
        soft.impactOccurred(intensity: 0.9)
    }

    static func toggle() {
        medium.impactOccurred(intensity: 0.8)
    }

    static func success() { notify(.success) }
    static func warning() { notify(.warning) }
    static func error() { notify(.error) }

    private static func notify(_ type: UINotificationFeedbackGenerator.FeedbackType) {
        guard Date().timeIntervalSince(lastNotification) > 0.6 else { return }
        lastNotification = Date()
        notification.notificationOccurred(type)
    }
}
