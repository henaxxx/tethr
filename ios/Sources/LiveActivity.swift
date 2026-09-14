import ActivityKit
import Foundation

/// ダイナミックアイランドとロック画面の表示（Live Activity）を出し入れする。
///
/// 新しく出せるのはアプリが前面にいるときだけ。背面では、出ているものを書き換えるか消すことしかできない。
/// 書き換えと消去が前後しないよう、1 つずつ順番に処理する
@MainActor
final class LiveActivityController {

    typealias State = TethrActivityAttributes.ContentState

    private var activity: Activity<TethrActivityAttributes>?
    private var sent: State?
    private var sentName: String?
    private var sentAt = Date.distantPast
    private var work: Task<Void, Never>?

    init() {
        // 前回アプリが終了させられたときの表示が残っていたら片付ける
        enqueue {
            for old in Activity<TethrActivityAttributes>.activities {
                await old.end(nil, dismissalPolicy: .immediate)
            }
        }
    }

    /// 中身を出す。まだ出ていなければ、前面にいるときだけ新しく出す
    func show(name: String, state: State, appActive: Bool) {
        enqueue { [weak self] in await self?.apply(name: name, state: state, appActive: appActive) }
    }

    /// 消す。final を渡すと、ロック画面に最後の中身を after 秒だけ残す（ダイナミックアイランドからはすぐ消える）
    func end(final state: State? = nil, after seconds: TimeInterval? = nil) {
        enqueue { [weak self] in await self?.finish(final: state, after: seconds) }
    }

    private func enqueue(_ job: @escaping @MainActor () async -> Void) {
        let previous = work
        work = Task { @MainActor in
            await previous?.value
            await job()
        }
    }

    private func apply(name: String, state: State, appActive: Bool) async {
        if let activity, activity.activityState == .active {
            if name != sentName {
                // 機種名は途中で変えられない。出し直す
                await finish(final: nil, after: nil)
            } else {
                // 同じ中身でも、古くなった扱いにされないよう数分おきには送り直す
                guard state != sent || Date().timeIntervalSince(sentAt) > 300 else { return }
                await activity.update(content(state))
                sent = state
                sentAt = Date()
                return
            }
        }
        guard appActive, ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        do {
            activity = try Activity.request(attributes: TethrActivityAttributes(cameraName: name), content: content(state))
            sent = state
            sentName = name
            sentAt = Date()
            DebugLog.write("Live Activity: 表示を始めた（\(state.phase.rawValue)）")
        } catch {
            DebugLog.write("Live Activity: 出せない \(error.localizedDescription)")
        }
    }

    private func finish(final state: State?, after seconds: TimeInterval?) async {
        guard let activity else { return }
        self.activity = nil
        sent = nil
        sentName = nil
        let policy: ActivityUIDismissalPolicy = seconds.map { .after(Date().addingTimeInterval($0)) } ?? .immediate
        await activity.end(state.map { ActivityContent(state: $0, staleDate: nil) }, dismissalPolicy: policy)
        DebugLog.write("Live Activity: 表示を終えた")
    }

    /// アプリが知らせずに止められたときに、いつまでも「接続中」と出し続けないよう期限を付ける
    private func content(_ state: State) -> ActivityContent<State> {
        let stale = state.keepUntil.map { $0.addingTimeInterval(15) } ?? Date().addingTimeInterval(15 * 60)
        return ActivityContent(state: state, staleDate: stale)
    }
}
