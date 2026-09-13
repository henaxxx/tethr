import CoreLocation
import CoreMotion

/// 撮影時の位置を控えておくための現在地取得。
///
/// カメラのカードには書き込めないので、位置情報を写真本体に
/// 焼き込むことはできない。代わりに撮影の瞬間の位置を記録しておき、
/// 端末へ取り込むときに写真アプリの資産情報として付ける。
///
/// 電力の多くは衛星測位が食う。そこで、動いている間だけ精密に測り、
/// 立ち止まっている間は衛星を止めて最後の精密な位置を持っておく。
/// 動いているかどうかはモーション用の専用チップが判定するので、判定自体に電力はほぼ要らない。
/// 写真を撮るときは立ち止まるので、撮影中の大半は衛星が止まっていることになる。
/// モーションの許可が無い、または使えない端末では、今までどおり衛星を回し続ける。
final class LocationProvider: NSObject, CLLocationManagerDelegate {

    enum Mode: String {
        case off        // 記録していない
        case precise    // 衛星で測っている
        case holding    // 立ち止まっているので衛星を止め、最後の精密な位置を持っている
    }

    private let manager = CLLocationManager()
    private let motion = CMMotionActivityManager()
    private(set) var current: CLLocation?
    private(set) var mode: Mode = .off {
        didSet {
            guard mode != oldValue else { return }
            DebugLog.write("GPS: \(mode.rawValue)")
            onModeChange?(mode)
        }
    }
    /// 新しい位置が来るたびに呼ばれる。軌跡の記録に使う。
    var onUpdate: ((CLLocation) -> Void)?
    var onModeChange: ((Mode) -> Void)?

    /// 背面でも記録を続けるか。撮影の合間に画面を消しても軌跡を切らさないため。
    var continueInBackground = false {
        didSet { applyBackgroundMode() }
    }
    var enabled = false {
        didSet {
            guard enabled != oldValue else { return }
            enabled ? begin() : end()
        }
    }

    private var inForeground = true
    /// 立ち止まった時刻。動き出したら nil
    private var stationarySince: Date?
    private var holdTask: Task<Void, Never>?
    /// 立ち止まってからこの秒数たったら衛星を止める。立ち止まりかけの足踏みで止めないため
    private static let holdAfter: TimeInterval = 30
    /// 衛星を止めたときに持っておく位置。動き出したら捨てる
    private var heldFix: CLLocation?
    /// 撮影ごとの、精密な位置の待ち
    private var fixWaiters: [(CLLocation?) -> Void] = []
    private var boostTask: Task<Void, Never>?
    private var boosting = false
    /// 立ち止まっている間も軌跡に点を打つ。GeoLog.estimateLocation の前提
    private var heartbeatTask: Task<Void, Never>?
    /// 軌跡の最後の点の時刻。打ち直すかどうかをこれで決める
    var lastRecordedTime: (() -> Date?)?

    override init() {
        super.init()
        manager.delegate = self
        // 写真の位置情報に測量精度は要らない。
        manager.desiredAccuracy = kCLLocationAccuracyNearestTenMeters
        manager.distanceFilter = 10
    }

    var authorized: Bool {
        switch manager.authorizationStatus {
        case .authorizedWhenInUse, .authorizedAlways: return true
        default: return false
        }
    }

    // MARK: 開始と停止

    private func begin() {
        switch manager.authorizationStatus {
        case .notDetermined:
            manager.requestWhenInUseAuthorization()
        case .authorizedWhenInUse, .authorizedAlways:
            applyBackgroundMode()
            goPrecise()
            startMotion()
            startHeartbeat()
        default:
            break
        }
    }

    /// 立ち止まっている間は位置の更新が来ない（10m 動くまで来ないうえ、30 秒で衛星も止める）ので、軌跡に点が残らない。
    /// すると「記録していたが動かなかった」と「アプリを閉じていて記録していなかった」の見分けがつかず、
    /// 撮影時刻から位置を引くときに空白を埋めてよいか判断できない。そこで、動いていないと分かっているときだけ
    /// 軌跡の点の間が 5 分（TrackTiming.interval）を超えないよう打ち直す。動いているのに更新が来ない（地下など）ときは打たない。
    /// 5 分ちょうどに打つとタイマーの遅れで 5 分を少し超え、埋める判定に落ちるので、最後の点から 4 分を過ぎたら打つ
    private func startHeartbeat() {
        heartbeatTask?.cancel()
        heartbeatTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(15))
                guard let self, !Task.isCancelled else { return }
                if let last = self.lastRecordedTime?(), Date().timeIntervalSince(last) < TrackTiming.interval - 60 { continue }
                guard self.enabled, self.inForeground, self.stationarySince != nil || self.mode == .holding,
                      let base = self.heldFix ?? self.current,
                      base.horizontalAccuracy >= 0, base.horizontalAccuracy <= 65 else { continue }
                self.onUpdate?(CLLocation(coordinate: base.coordinate, altitude: base.altitude,
                                          horizontalAccuracy: base.horizontalAccuracy,
                                          verticalAccuracy: base.verticalAccuracy, timestamp: Date()))
            }
        }
    }

    private func end() {
        stopMotion()
        heartbeatTask?.cancel()
        holdTask?.cancel()
        boostTask?.cancel()
        boosting = false
        manager.allowsBackgroundLocationUpdates = false
        manager.stopUpdatingLocation()
        heldFix = nil
        flushWaiters(with: nil)
        mode = .off
    }

    private func applyBackgroundMode() {
        guard authorized else { return }
        // 許可されていない状態で立てると例外になるので、状態を見てから触る
        manager.allowsBackgroundLocationUpdates = continueInBackground && enabled
        manager.pausesLocationUpdatesAutomatically = false
        manager.showsBackgroundLocationIndicator = continueInBackground
    }

    func appDidEnterBackground() {
        inForeground = false
        stopMotion()
        holdTask?.cancel()
        // 背面での記録は衛星を回し続けないと止まる。モーション判定も背面では届かない
        if enabled && authorized && continueInBackground { goPrecise() }
    }

    func appDidBecomeActive() {
        inForeground = true
        guard enabled, authorized else { return }
        goPrecise()
        startMotion()
    }

    // MARK: 立ち止まりの判定

    private func goPrecise() {
        holdTask?.cancel()
        heldFix = nil
        manager.desiredAccuracy = kCLLocationAccuracyNearestTenMeters
        manager.distanceFilter = 10
        manager.startUpdatingLocation()
        mode = .precise
    }

    private func goHolding() {
        // 直近の精密な位置が無いまま止めると、撮影に付ける位置が無くなる。取れるまで待つ
        guard let fix = current, fix.horizontalAccuracy >= 0, fix.horizontalAccuracy <= 65,
              fix.timestamp.timeIntervalSinceNow > -90 else { return }
        heldFix = fix
        if !boosting { manager.stopUpdatingLocation() }
        mode = .holding
    }

    private func startMotion() {
        guard inForeground, CMMotionActivityManager.isActivityAvailable() else { return }
        switch CMMotionActivityManager.authorizationStatus() {
        case .denied, .restricted:
            return   // 判定できないので衛星を回し続ける
        default:
            break
        }
        motion.startActivityUpdates(to: .main) { [weak self] activity in
            guard let self, let activity else { return }
            self.handle(activity)
        }
    }

    private func stopMotion() {
        motion.stopActivityUpdates()
        stationarySince = nil
    }

    private func handle(_ a: CMMotionActivity) {
        let moving = a.walking || a.running || a.cycling || a.automotive
        if moving {
            stationarySince = nil
            holdTask?.cancel()
            if mode == .holding {
                DebugLog.write("動き出した")
                goPrecise()
            }
        } else if a.stationary && a.confidence != .low {
            guard stationarySince == nil else { return }
            stationarySince = Date()
            holdTask?.cancel()
            holdTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(Self.holdAfter))
                guard let self, !Task.isCancelled, self.stationarySince != nil, self.mode == .precise else { return }
                self.goHolding()
            }
        }
        // 判定がつかないときは今の状態を保つ
    }

    // MARK: 撮影の瞬間の位置

    private func isPrecise(_ l: CLLocation) -> Bool {
        l.horizontalAccuracy >= 0 && l.horizontalAccuracy <= 30
    }

    /// 撮影の瞬間に呼ぶ。手持ちの位置で足りればすぐ返し、
    /// 足りなければ衛星を起こして、精密に取れた位置を返す（最大 20 秒）。
    func fixForShot(_ callback: @escaping (CLLocation?) -> Void) {
        guard enabled, authorized else { callback(nil); return }
        switch mode {
        case .holding:
            // 立ち止まってから動いていないので、止める直前の位置がそのまま撮影地点
            if let held = heldFix { callback(held); return }
        case .precise:
            if let c = current, isPrecise(c), c.timestamp.timeIntervalSinceNow > -15 { callback(c); return }
        case .off:
            callback(current); return
        }
        fixWaiters.append(callback)
        boost()
    }

    private func boost() {
        guard !boosting else { return }
        boosting = true
        if mode != .precise {
            manager.desiredAccuracy = kCLLocationAccuracyNearestTenMeters
            manager.startUpdatingLocation()
            DebugLog.write("GPS: 撮影のため一時的に起こす")
        }
        boostTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(20))
            guard let self, !Task.isCancelled else { return }
            // 精密に取れなかった。手持ちで一番新しいものを渡す
            self.flushWaiters(with: self.current)
            self.endBoost(with: nil)
        }
    }

    private func endBoost(with fix: CLLocation?) {
        boostTask?.cancel()
        boosting = false
        if mode == .holding {
            if let fix { heldFix = fix }
            manager.stopUpdatingLocation()
        }
    }

    private func flushWaiters(with location: CLLocation?) {
        let waiters = fixWaiters
        fixWaiters = []
        waiters.forEach { $0(location) }
    }

    // MARK: CLLocationManagerDelegate

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        guard enabled, authorized else { return }
        applyBackgroundMode()
        if mode == .off { goPrecise() }
        startMotion()
        if heartbeatTask == nil { startHeartbeat() }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let latest = locations.last else { return }
        current = latest
        onUpdate?(latest)
        guard isPrecise(latest) else { return }
        flushWaiters(with: latest)
        if boosting { endBoost(with: latest) }
        // 精密な位置が取れるまで止めるのを待っていた
        if mode == .precise, let since = stationarySince, Date().timeIntervalSince(since) >= Self.holdAfter {
            goHolding()
        }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {}
}
