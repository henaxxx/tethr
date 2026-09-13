import UIKit

/// iPhone がポケットに入っているか。近接センサで見る。
///
/// 近接監視を有効にすると、センサが覆われたときに iOS が画面を消し、アプリは前面のまま動き続ける
/// （通話中の電話と同じ）。覆われている間だけ自動ロックを止め、ポケットの中でロックされて
/// GPS や撮影通知が止まらないようにする。取り出したら自動ロックを元に戻す。
///
/// 近接センサの通知は画面が縦向きのときしか届かないという報告があるため、アプリは縦に固定している。
@MainActor
final class PocketDetector {

    private(set) var pocketed = false
    var onChange: ((Bool) -> Void)?

    /// カメラがつながっていて、アプリが前面にあり、設定が有効なときだけ監視する
    var active = false {
        didSet {
            guard active != oldValue else { return }
            UIDevice.current.isProximityMonitoringEnabled = active
            if active && !UIDevice.current.isProximityMonitoringEnabled {
                DebugLog.write("近接センサが使えない端末")
            }
            if !active { settle(false) } else { proximityChanged() }
        }
    }

    private var enterTask: Task<Void, Never>?
    private var batteryLog: Task<Void, Never>?

    init() {
        UIDevice.current.isBatteryMonitoringEnabled = true
        NotificationCenter.default.addObserver(
            forName: UIDevice.proximityStateDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.proximityChanged() }
        }
    }

    private func proximityChanged() {
        let covered = active && UIDevice.current.isProximityMonitoringEnabled && UIDevice.current.proximityState
        enterTask?.cancel()
        if covered {
            // 手がセンサをかすめただけで切り替わらないよう、2 秒覆われ続けたらポケットとみなす。
            // 画面を消すのは iOS がすぐに行うので、ここで待っても電力の損は無い
            enterTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled else { return }
                self?.settle(true)
            }
        } else {
            settle(false)
        }
    }

    private func settle(_ value: Bool) {
        guard value != pocketed else { return }
        pocketed = value
        UIApplication.shared.isIdleTimerDisabled = value
        DebugLog.write("\(value ? "ポケットに入った" : "取り出した") 電池 \(batteryPercent)%")
        batteryLog?.cancel()
        if value {
            // 省電力の効き目を後から確かめるため、ポケットの中にいる間の電池残量を残す
            batteryLog = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(300))
                    guard !Task.isCancelled, let self else { return }
                    DebugLog.write("ポケット中 電池 \(self.batteryPercent)%")
                }
            }
        }
        onChange?(value)
    }

    private var batteryPercent: Int { Int((UIDevice.current.batteryLevel * 100).rounded()) }
}
