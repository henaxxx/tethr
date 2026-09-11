import CoreLocation

/// 撮影時の位置を控えておくための現在地取得。
///
/// カメラのカードには書き込めないので、位置情報を写真本体に
/// 焼き込むことはできない。代わりに「カットが届いた瞬間の位置」を
/// 記録しておき、端末へ取り込むときに写真アプリの資産情報として付ける。
/// カットは撮影から 1〜2 秒で届くため、この位置は撮影地点と実質同じになる。
final class LocationProvider: NSObject, CLLocationManagerDelegate {

    private let manager = CLLocationManager()
    private(set) var current: CLLocation?
    /// 新しい位置が来るたびに呼ばれる。軌跡の記録に使う。
    var onUpdate: ((CLLocation) -> Void)?
    /// 背面でも記録を続けるか。撮影の合間に画面を消しても軌跡を切らさないため。
    var continueInBackground = false {
        didSet { applyBackgroundMode() }
    }
    var enabled = false {
        didSet {
            if enabled { begin() } else {
                manager.allowsBackgroundLocationUpdates = false
                manager.stopUpdatingLocation()
            }
        }
    }

    override init() {
        super.init()
        manager.delegate = self
        // 写真の位置情報に測量精度は要らない。消費電力を抑える。
        manager.desiredAccuracy = kCLLocationAccuracyNearestTenMeters
        manager.distanceFilter = 10
    }

    var authorized: Bool {
        switch manager.authorizationStatus {
        case .authorizedWhenInUse, .authorizedAlways: return true
        default: return false
        }
    }

    private func begin() {
        switch manager.authorizationStatus {
        case .notDetermined: manager.requestWhenInUseAuthorization()
        case .authorizedWhenInUse, .authorizedAlways:
            applyBackgroundMode()
            manager.startUpdatingLocation()
        default: break
        }
    }

    private func applyBackgroundMode() {
        guard authorized else { return }
        // 許可されていない状態で立てると例外になるので、状態を見てから触る
        manager.allowsBackgroundLocationUpdates = continueInBackground && enabled
        manager.pausesLocationUpdatesAutomatically = !continueInBackground
        manager.showsBackgroundLocationIndicator = continueInBackground
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        if enabled, authorized { manager.startUpdatingLocation() }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let latest = locations.last else { return }
        current = latest
        onUpdate?(latest)
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {}
}
