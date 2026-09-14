import BackgroundTasks
import Foundation
import UIKit

/// 選んだカットを順に写真アプリへ取り込む。
///
/// iOS は背面のアプリへのカメラの配信を約 30 秒で止める（実機で確認）。取り込みが 30 秒で終わらないことは多いので、
/// 取り込み中は画面を自動で消さず、ホーム画面に回ったら待ち、戻ったら残りから続ける。
/// iOS 26 以降では BGContinuedProcessingTask も申請して、背面でも続けられるかを試す（開発版のログで確かめる）
@MainActor
final class BatchImporter: ObservableObject {

    struct Progress: Equatable {
        var total: Int
        var done: Int
        var failed: [String] = []
        var current: String?
        /// 接続を休ませている・つなぎ直しているなどで、再開を待っている
        var waiting = false
    }

    @Published private(set) var progress: Progress?
    /// 直前の取り込みの結果（「12 枚を保存しました」など）。次を始めると消える
    @Published private(set) var lastResult: String?

    weak var session: CameraSession?

    /// 背面でも続ける許可（BGContinuedProcessingTask）の識別子。Info.plist の BGTaskSchedulerPermittedIdentifiers と揃える
    static let taskIdentifier = "app.tethr.TethrTouch.import"
    /// 起動時に登録したハンドラから、動いている取り込みを見つけるため
    private static weak var current: BatchImporter?

    private var queue: [String] = []
    private var worker: Task<Void, Never>?
    private var cancelled = false
    /// iOS 26 の BGContinuedProcessingTask（型を持てない OS もあるので AnyObject で持つ）
    private var continuedTask: AnyObject?
    private var lastProgressAt = Date.distantPast

    var isRunning: Bool { progress != nil }

    /// 背面でも続ける許可が下りていて、取り込みが進んでいる間は、接続を休ませずに保つ期限
    var keepSessionUntil: Date? {
        guard continuedTask != nil, progress != nil else { return nil }
        return lastProgressAt.addingTimeInterval(20)
    }

    // MARK: 始める・止める

    func start(_ names: Set<String>) {
        guard let session, progress == nil else { return }
        // 撮影順（古い順）に入れる。写真アプリの並びと、途中で止まったときの分かりやすさのため
        let shots = names.compactMap { session.shot(named: $0) }
            .filter { !$0.imported }
            .sorted { ($0.captured ?? .distantPast) < ($1.captured ?? .distantPast) }
        guard !shots.isEmpty else { return }
        queue = shots.map(\.name)
        progress = Progress(total: queue.count, done: 0)
        lastResult = nil
        cancelled = false
        lastProgressAt = Date()
        Self.current = self
        UIApplication.shared.isIdleTimerDisabled = true
        DebugLog.write("まとめて取り込み: \(queue.count) 枚")
        submitContinuedTask(total: queue.count)
        worker = Task { await run() }
    }

    func cancel() {
        guard progress != nil else { return }
        cancelled = true
        DebugLog.write("まとめて取り込み: 止めた")
    }

    func clearResult() {
        lastResult = nil
    }

    // MARK: 取り込む

    private func run() async {
        while let name = queue.first, !cancelled {
            guard let session else { break }
            guard let shot = session.shot(named: name) else {
                // カードから消えた（別のカードに替えたなど）
                queue.removeFirst()
                progress?.failed.append(name)
                continue
            }
            if shot.imported {
                queue.removeFirst()
                advance()
                continue
            }
            // 背面で接続を休ませた、つなぎ直している、カードの一覧がまだ届いていない。戻るまで待つ
            guard session.canImport(name) else {
                if progress?.waiting == false {
                    progress?.waiting = true
                    DebugLog.write("まとめて取り込み: 再開を待つ（\(name)）")
                }
                try? await Task.sleep(for: .milliseconds(500))
                continue
            }
            if progress?.waiting == true {
                progress?.waiting = false
                DebugLog.write("まとめて取り込み: 再開")
            }
            progress?.current = name
            let started = Date()
            let saved = await session.importShot(shot, reportErrors: false)
            if !saved {
                // 背面で接続が止められた・休ませた。戻ったら同じカットからやり直す
                if !session.canImport(name) || !session.isAppActive { continue }
                queue.removeFirst()
                progress?.failed.append(name)
                DebugLog.write("まとめて取り込み: 失敗 \(name)")
                continue
            }
            #if DEBUG
            if !session.isAppActive {
                DebugLog.write(String(format: "まとめて取り込み: 背面で保存 %@ %.1f 秒", name, Date().timeIntervalSince(started)))
            }
            #endif
            queue.removeFirst()
            advance()
        }
        finish()
    }

    private func advance() {
        progress?.done += 1
        progress?.current = nil
        lastProgressAt = Date()
        updateContinuedTask()
    }

    private func finish() {
        guard let result = progress else { return }
        let saved = result.done
        let skipped = result.total - result.done - result.failed.count
        progress = nil
        queue = []
        worker = nil
        UIApplication.shared.isIdleTimerDisabled = session?.pocketed ?? false
        completeContinuedTask(success: !cancelled && result.failed.isEmpty)
        var text = String(localized: "\(saved) 枚を写真に保存しました")
        if !result.failed.isEmpty {
            text += String(localized: "（\(result.failed.count) 枚は取り込めませんでした）")
        } else if cancelled, skipped > 0 {
            text += String(localized: "（残り \(skipped) 枚は止めました）")
        }
        lastResult = text
        DebugLog.write("まとめて取り込み: 終わり \(text)")
        if saved > 0 { Haptics.success() }
    }

    // MARK: 背面でも続ける（iOS 26 以降）

    /// 起動の途中で登録しておく（BGTaskScheduler の決まり）
    static func registerBackgroundTask() {
        guard #available(iOS 26.0, *) else { return }
        let registered = BGTaskScheduler.shared.register(forTaskWithIdentifier: taskIdentifier, using: .main) { task in
            MainActor.assumeIsolated {
                guard let importer = BatchImporter.current, importer.progress != nil else {
                    task.setTaskCompleted(success: true)
                    return
                }
                importer.adopt(task)
            }
        }
        if !registered { DebugLog.write("まとめて取り込み: 背面で続けるハンドラを登録できない") }
    }

    private func submitContinuedTask(total: Int) {
        guard #available(iOS 26.0, *) else { return }
        let request = BGContinuedProcessingTaskRequest(
            identifier: Self.taskIdentifier,
            title: String(localized: "写真を取り込み中"),
            subtitle: String(localized: "0 / \(total) 枚")
        )
        // すぐに始められないなら、待たせずにあきらめる（前面で続ければよい）
        request.strategy = .fail
        do {
            try BGTaskScheduler.shared.submit(request)
            DebugLog.write("まとめて取り込み: 背面で続ける申請をした")
        } catch {
            DebugLog.write("まとめて取り込み: 背面で続ける申請が通らない \(error)")
        }
    }

    private func adopt(_ task: BGTask) {
        guard #available(iOS 26.0, *), let task = task as? BGContinuedProcessingTask, let progress else {
            task.setTaskCompleted(success: false)
            return
        }
        continuedTask = task
        task.progress.totalUnitCount = Int64(progress.total)
        task.progress.completedUnitCount = Int64(progress.done)
        task.expirationHandler = { [weak self] in
            Task { @MainActor in
                // 利用者が止めたか、iOS が打ち切った。前面に戻れば続きから取り込む
                DebugLog.write("まとめて取り込み: 背面で続ける許可が切れた")
                self?.continuedTask = nil
            }
        }
        DebugLog.write("まとめて取り込み: 背面で続ける許可が下りた")
    }

    private func updateContinuedTask() {
        guard #available(iOS 26.0, *), let task = continuedTask as? BGContinuedProcessingTask, let progress else { return }
        task.progress.completedUnitCount = Int64(progress.done)
        task.updateTitle(task.title, subtitle: String(localized: "\(progress.done) / \(progress.total) 枚"))
    }

    private func completeContinuedTask(success: Bool) {
        guard #available(iOS 26.0, *), let task = continuedTask as? BGContinuedProcessingTask else { return }
        task.setTaskCompleted(success: success)
        continuedTask = nil
    }
}
