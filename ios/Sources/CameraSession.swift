import Foundation
import ImageCaptureCore
import UIKit
import Photos
import CoreLocation

enum LinkState: Equatable {
    case idle
    case unauthorized
    case searching
    case connecting(String)
    case connected(String)
    case failed(String)
}

/// ImageCaptureCore を包んで、カメラとの一連のやり取りを引き受ける。
///
/// iOS には撮影や設定変更の高レベル API が無いため、
/// それらは生の PTP コマンドで行う（実機で動作を確認済み）。
@MainActor
final class CameraSession: NSObject, ObservableObject {

    @Published private(set) var state: LinkState = .idle {
        didSet { updatePocketWatch() }
    }
    /// 接続中に撮ったカット。テザー撮影の主役はこちら。
    @Published private(set) var liveShots: [Shot] = []
    /// 接続前からカードにあったカット。見たい人だけが見る。
    @Published private(set) var cardShots: [Shot] = []
    @Published private(set) var catalogReady = false
    @Published private(set) var catalogProgress = 0
    @Published var browsingCard = false
    @Published private(set) var props: [PTP.Prop: PropDesc] = [:]
    @Published private(set) var busy = false
    /// 露出計の振れ（EV）。カメラが 1/6 EV 刻みの整数で持っている。
    @Published private(set) var lightMeter: Double?

    /// 露出計が意味を持つか。
    ///
    /// Nikon の露出インジケータは M モードでだけ「適正露出からのずれ」を示す。
    /// P・A・S ではカメラがシャッタースピードや絞りを自動で動かして適正に合わせるので振れない
    /// （D300 で確認。半押しで変わるのは 0x500D だけで、0xD1B1 は動かなかった）。
    /// 出しっぱなしにすると壊れているように見えるので、M 以外では隠す。
    var lightMeterMeaningful: Bool {
        props[.exposureProgram]?.current == 1 && lightMeterAvailable   // PTP の ExposureProgramMode: 1 = Manual
    }
    /// 撮影地点を記録するか。カメラ側には書けないので、
    /// 取り込み時に写真アプリへ渡す形で残す。
    /// 接続時に合わせたカメラ時計のずれ（秒）。正ならカメラが遅れていた。
    @Published private(set) var clockCorrection: TimeInterval?
    /// 撮影地点を記録するか。
    ///
    /// カメラの接続とは切り離す。軌跡の存在意義は
    /// 「テザーしていない間に撮ったカットを撮影時刻で拾う」ことなので、
    /// 繋がっていない時こそ記録している必要がある。
    @Published var geotagging = true {
        didSet {
            location.enabled = geotagging
            UserDefaults.standard.set(geotagging, forKey: "geotagging")
        }
    }
    @Published var selection: Shot.ID?
    @Published var lastError: String?

    private let browser = ICDeviceBrowser()
    private var camera: ICCameraDevice?
    /// ICCameraFile を撮影ファイル名で引けるようにしておく
    private var fileIndex: [String: ICCameraFile] = [:]
    /// サムネイル要求中・取得済みの名前。二重要求を防ぐ。
    private var thumbnailRequested: Set<String> = []
    private var previewRequested: Set<String> = []
    private var progressTimer: Timer?

    // 「接続後に撮ったカットか」を、読み込み完了の合図で決めてはいけない。
    // 実機で確かめたところ、USB を抜き差しした直後は完了の合図がほぼ空の時点で先に届き、
    // 写真はその後 45 秒かけて届く。合図を信じるとカードの古いカットが全部テザー側に流れ込み、
    // 現在地まで付いてしまう。逆に読み込み中に撮ったカットはカード側へ迷子になる。
    //
    // PTP のオブジェクトハンドルで照合したいところだが、iOS の ICCameraItem.ptpObjectHandle は
    // 常に 0 で使えなかった（D300 で確認）。そこで撮影時刻で切る。カメラの時計は接続のたびに
    // 合わせているので、ずれは小さい。合わせる前のずれも読んでおき、その分を補正する。

    /// 準備中。セッションは開いたが、フレームワークがカードを下調べしていて命令が通らない。
    /// 長さはカードの枚数に比例する（1 件約 17 ミリ秒、D300 で 408 件 7 秒・0 件 0.003 秒）
    @Published private(set) var preparing = false
    /// このカメラの前回のカード枚数。準備中に目安として出す
    @Published private(set) var lastKnownFileCount: Int?
    /// このカメラに初めてセッションを開いた時刻（端末の時計）。これより後に撮られたものがテザー側
    private var connectedAt: Date?
    /// 接続時点のカメラ時計のずれ（端末 − カメラ、秒）。正ならカメラが遅れていた
    private var clockDrift: TimeInterval?
    /// 時計を読み終えるまでは判定できないので、届いたファイルを溜めておく
    private var classifyReady = false
    private var pendingFiles: [ICCameraFile] = []
    /// 接続時点でカメラにあったオブジェクト数（フォルダを含む）。進み具合の分母
    private var expectedObjects: Int?
    /// 届いたファイル名。開き直しで同じものが届き直しても数え直さない
    private var deliveredNames: Set<String> = []
    /// 撮影の瞬間に届いた ObjectAdded の時刻と位置。古い順。
    /// セッションを閉じていても届く（実機で確認）ので、撮影地点の一番の手がかりになる
    private var shotEvents: [ShotEvent] = []
    private struct ShotEvent {
        let id: Int
        let time: Date
        /// 衛星が止まっていた等で精密な位置がまだ無ければ nil。取れたら埋める
        var location: CLLocation?
    }
    private var nextShotEventID = 0
    /// 精密な位置がまだ無い撮影通知を借りて、仮の位置で並べたカット（カット名 → 通知の番号）。
    /// その通知に位置が届いたら、借りていたカット全部に入れる
    private var provisionalShots: [String: Int] = [:]
    /// フレームワークが完了を告げたか。これだけでは完了とみなさない
    private var frameworkCatalogDone = false
    private var catalogSettle: Task<Void, Never>?
    /// 前につないでいたカメラ。同じカメラが挿し直されたら一覧を保つ
    private var lastCameraID: String?
    /// 背面に回るとき自分で閉じた。前面に戻ったら開き直す
    private var closedForBackground = false
    /// 閉じ終わる前に前面へ戻ってきた
    private var reopenAfterClose = false
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    private var eventLoop: Task<Void, Never>?
    /// 画面が見えていない、あるいは露出計が出ていない間は問い合わせない
    private var suspended = false
    /// Nikon が露出計を持っているプロパティ
    private static let lightMeterProp: UInt32 = 0xD1B1
    /// CheckEvent が使えない機種向けに、一度失敗したら直接読みに切り替える
    private var checkEventUsable = true
    /// サムネイルや取り込みが走っている間はポーリングを止める
    private var transferCount = 0
    private let location = LocationProvider()
    let geoLog = GeoLog()

    // MARK: ポケット
    //
    // カメラをつないだまま iPhone をポケットに入れて撮る使い方のための省電力。
    // 近接センサで画面を消し、アプリは前面のまま、撮影通知と位置の記録だけを続ける。
    // 背面レビューは USB 接続中の D300 では出せないので、取り出した瞬間に最新カットを全画面で出す。

    /// ポケットに入っていて画面が消えている
    @Published private(set) var pocketed = false
    /// ポケットの中で撮ったカットがあれば、取り出したときに全画面で出す
    @Published var reviewOnReturn: Shot.ID?
    /// ポケット検知を使うか
    @Published var pocketModeEnabled = true {
        didSet {
            UserDefaults.standard.set(pocketModeEnabled, forKey: "pocketMode")
            updatePocketWatch()
        }
    }
    /// いま衛星で測っているか。設定画面に出す
    @Published private(set) var gpsMode: LocationProvider.Mode = .off
    private let pocket = PocketDetector()
    /// ライブビュー。映像は別の観測対象に分けてあり、画面全体は描き直さない
    let live = LiveViewController()
    /// いまつないでいるカメラの識別子。カメラごとの覚え書きに使う
    var cameraIdentifier: String? { lastCameraID }
    private var appActive = true
    private var shotsWhilePocketed = 0
    /// ポケットの中で取らずにおいたサムネイル
    private var deferredThumbnails: Set<String> = []
    private var prefetchTask: Task<Void, Never>?

    /// スクラバーで操作する設定
    var adjustable: [PTP.Prop] {
        let shutter: PTP.Prop = (props[.nikonExposureTime]?.choices.isEmpty == false) ? .nikonExposureTime : .exposureTime
        return [shutter, .fNumber, .iso]
    }

    /// 軌跡を背面でも取り続けるか。撮影の合間に画面を消しても切れないようにする。
    @Published var trackInBackground = false {
        didSet { location.continueInBackground = trackInBackground }
    }

    override init() {
        super.init()
        browser.delegate = self
        geotagging = UserDefaults.standard.object(forKey: "geotagging") as? Bool ?? true
        location.enabled = geotagging
        location.onUpdate = { [weak self] loc in
            Task { @MainActor in
                guard let self, self.geotagging else { return }
                self.geoLog.recordTrack(loc)
            }
        }
        location.onModeChange = { [weak self] mode in
            Task { @MainActor in self?.gpsMode = mode }
        }
        pocketModeEnabled = UserDefaults.standard.object(forKey: "pocketMode") as? Bool ?? true
        pocket.onChange = { [weak self] value in self?.pocketChanged(value) }
        live.session = self
    }

    private func updatePocketWatch() {
        pocket.active = pocketModeEnabled && isConnected && appActive
    }

    private func pocketChanged(_ value: Bool) {
        pocketed = value
        if value {
            shotsWhilePocketed = 0
            // 誰も見ていないのに映像を取り続けても電池を食うだけ
            Task { await live.stop(reason: "ポケットに入れた") }
            return
        }
        // 取り出した。止めていたものを戻す
        let names = deferredThumbnails
        deferredThumbnails = []
        for shot in liveShots + cardShots where names.contains(shot.name) {
            requestThumbnail(for: shot)
        }
        Task { await refreshProps() }
        if shotsWhilePocketed > 0, let newest = liveShots.first {
            DebugLog.write("取り出し: ポケット中に \(shotsWhilePocketed) カット。最新を全画面へ")
            browsingCard = false
            selection = newest.id
            reviewOnReturn = newest.id
        }
        shotsWhilePocketed = 0
    }

    /// ポケットの中で撮られたら、撮影が 3 秒途切れたところで最新 1 枚のプレビューだけ取っておく。
    /// 取り出してから転送を待たせないため。連写中は 1 枚ごとに取らない
    private func schedulePrefetch() {
        prefetchTask?.cancel()
        prefetchTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard let self, !Task.isCancelled, self.pocketed, let newest = self.liveShots.first else { return }
            DebugLog.write("最新カットのプレビューを先読み: \(newest.name)")
            self.requestPreview(for: newest)
        }
    }

    /// 撮影通知に対して、精密な位置が後から取れた
    private func applyShotFix(id: Int, _ fix: CLLocation?) {
        guard let fix else {
            // 取れなかった。仮の位置のままにする
            provisionalShots = provisionalShots.filter { $0.value != id }
            return
        }
        if let i = shotEvents.firstIndex(where: { $0.id == id }) { shotEvents[i].location = fix }
        // 連写では 1 つの通知を何枚ものカットが借りている。全部に入れる
        for (name, eventID) in provisionalShots where eventID == id {
            provisionalShots[name] = nil
            if let i = liveShots.firstIndex(where: { $0.name == name }) { liveShots[i].location = fix }
            geoLog.recordShot(name, at: fix)
            DebugLog.write("位置を後から確定: \(name) 精度 \(Int(fix.horizontalAccuracy))m")
        }
    }

    var cameraName: String {
        switch state {
        case .connected(let n), .connecting(let n): return n
        default: return "未接続"
        }
    }

    var isConnected: Bool {
        if case .connected = state { return true }
        return false
    }

    /// いま画面に出すカット
    var shots: [Shot] { browsingCard ? cardShots : liveShots }

    // MARK: 接続

    func start() {
        // シミュレータの ImageCaptureCore にはこの機能が入っておらず、呼ぶと落ちる。
        // 実機では常にあるが、無い環境で即終了しないよう確かめてから呼ぶ
        guard browser.responds(to: NSSelectorFromString("requestContentsAuthorizationWithCompletion:")) else {
            state = .failed(String(localized: "この端末ではカメラに接続できません"))
            return
        }
        state = .searching
        browser.requestContentsAuthorization { [weak self] status in
            Task { @MainActor in
                guard let self else { return }
                guard status == .authorized else {
                    self.state = .unauthorized
                    return
                }
                self.browser.browsedDeviceTypeMask = ICDeviceTypeMask(
                    rawValue: ICDeviceTypeMask.camera.rawValue | ICDeviceLocationTypeMask.local.rawValue
                )!
                self.browser.start()
            }
        }
    }

    /// DeviceInfo から分かる、このカメラが受け付ける命令とプロパティ。読むまでは nil
    @Published private(set) var capabilities: CameraCapabilities?
    /// 送らずに断った命令。ログを 1 回ずつにする
    private var refusalsLogged: Set<String> = []

    /// ライブビューを出せるか。Nikon 1 はまだ手順を確かめていない（J1 は開始命令自体を名乗っていない）
    var supportsLiveView: Bool {
        PropFormat.vendor == PropFormat.vendorNikon && capabilities?.isNikon1 != true
    }

    /// DeviceInfo に露出まわりの設定が 1 つも載っていない（J1 は電池と時計だけ）
    var cannotAdjustSettings: Bool {
        guard isConnected, let caps = capabilities else { return false }
        return !(PTP.Prop.allCases.contains { $0 != .batteryLevel && caps.properties.contains($0.rawValue) })
    }

    /// 露出計（Nikon 0xD1B1）を読めるか
    var lightMeterAvailable: Bool {
        guard let caps = capabilities, caps.isNikon1 else { return true }
        return caps.properties.contains(UInt16(Self.lightMeterProp))
    }

    /// 手で接続を解除した。ケーブルを挿し直すまでは自動でつなぎ直さない
    @Published private(set) var userDisconnected = false
    /// つないでいる（あるいは解除した）カメラの機種名
    var deviceName: String? { camera?.name }

    /// 手で接続を解除する。セッションを閉じるだけでカメラの参照は保つので、
    /// 同じカメラなら「接続」で一瞬で戻れる（開き直しは 0.1 秒、D300 の実測）。
    /// ケーブルを挿し直したときは解除を忘れて、いつもどおり自動でつなぐ
    func disconnect() {
        guard let cam = camera, isConnected, !busy, !userDisconnected else { return }
        userDisconnected = true
        Task {
            // ライブビューは閉じる前に必ず止める。ミラーと記録先を元に戻さないとカードに保存されなくなる
            if live.isActive { await live.stop(reason: "接続解除") }
            eventLoop?.cancel()
            prefetchTask?.cancel()
            DebugLog.write("接続解除: セッションを閉じる")
            cam.requestCloseSession(options: nil) { [weak self] _ in
                Task { @MainActor in self?.sessionDidClose(cam) }
            }
            state = .idle
        }
    }

    /// 手で戻した接続が開いたら、操作できるようになったと手応えで知らせる
    private var announceNextOpen = false

    /// 手で解除した接続を戻す
    func reconnect() {
        guard userDisconnected, let cam = camera, !cam.hasOpenSession else { return }
        userDisconnected = false
        announceNextOpen = true
        reopen(cam, reason: "接続")
    }

    // MARK: 前面と背面

    /// 背面に回るときはセッションを自分で閉じる。
    ///
    /// 開いたまま iOS に落とされると、カメラ側に接続が半開きで残り、
    /// 次の接続で 20〜36 秒待たされる。行儀よく閉じておけば 7 秒で済む。
    /// 同じカメラのままなら、開き直しは 0.1 秒（いずれも D300 の実測）。
    func appDidEnterBackground() {
        appActive = false
        updatePocketWatch()
        location.appDidEnterBackground()
        guard let cam = camera, cam.hasOpenSession else { return }
        closedForBackground = true
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "close-camera-session") { [weak self] in
            Task { @MainActor in self?.endBackgroundTask() }
        }
        Task {
            // ライブビュー中なら、閉じる前に必ず止める。止める命令を省くとミラーが上がったまま残り、
            // 記録先も SDRAM のままになってカードに保存されなくなる
            if live.isActive { await live.stop(reason: "背面へ") }
            eventLoop?.cancel()
            if case .connected(let n) = state { state = .connecting(n) }
            DebugLog.write("背面へ: セッションを閉じる")
            cam.requestCloseSession(options: nil) { [weak self] _ in
                Task { @MainActor in
                    self?.sessionDidClose(cam)
                    self?.endBackgroundTask()
                }
            }
        }
    }

    func appDidBecomeActive() {
        appActive = true
        updatePocketWatch()
        location.appDidBecomeActive()
        guard closedForBackground, let cam = camera else { return }
        closedForBackground = false
        if cam.hasOpenSession {
            reopenAfterClose = true
        } else {
            reopen(cam)
        }
    }

    private var closeHandledAt: Date?

    /// セッションが閉じた。
    ///
    /// 完了ハンドラ付きで閉じると、デリゲートの didCloseSession は呼ばれない（実機のログで一度も出ていなかった）。
    /// そのため前回の終了時刻が残らず、背面から早く戻ったときの開き直しも走っていなかった。両方の経路からここに来る
    private func sessionDidClose(_ device: ICDevice) {
        UserDefaults.standard.set(Date(), forKey: "lastSessionEnded")
        guard device === camera else { return }
        // 万一両方の経路から届いても、開き直しの直後に「未接続」へ戻さないよう 1 回だけ扱う
        if let last = closeHandledAt, Date().timeIntervalSince(last) < 2 { return }
        closeHandledAt = Date()
        DebugLog.write("セッションを閉じた")
        if reopenAfterClose, let cam = camera {
            reopenAfterClose = false
            reopen(cam)
        } else if !closedForBackground {
            state = .idle
        }
    }

    private func reopen(_ cam: ICCameraDevice, reason: String = "前面へ") {
        DebugLog.write("\(reason): セッションを開き直す")
        state = .connecting(cam.name ?? String(localized: "カメラ"))
        cam.requestOpenSession()
    }

    private func endBackgroundTask() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }

    // MARK: カードの中身

    /// メーカーを読む。白バランス等の独自の値の読み方がメーカーで違うため
    private func readVendor() async {
        let data: Data
        do {
            data = try await send(.getDeviceInfo)
        } catch {
            DebugLog.write("DeviceInfo を読めない: \(describe(error))")
            return
        }
        guard let info = Self.parseDeviceInfo(data) else {
            DebugLog.write("DeviceInfo を解釈できない（\(data.count) バイト）")
            return
        }
        supportedProperties = info.properties
        capabilities = CameraCapabilities(info)
        #if DEBUG
        func hex(_ codes: [UInt16]) -> String { codes.map { String(format: "%04X", $0) }.joined(separator: " ") }
        DebugLog.write("DeviceInfo: \(info.manufacturer) \(info.model)\(capabilities?.isNikon1 == true ? "（Nikon 1）" : "")")
        DebugLog.write("DeviceInfo 命令: " + hex(info.operations))
        DebugLog.write("DeviceInfo イベント: " + hex(info.events))
        DebugLog.write("DeviceInfo プロパティ: " + hex(info.properties))
        #endif
        var vendor = info.vendor
        // D300 は VendorExtensionID に Microsoft（0x6 = MTP）を名乗る。
        // libgphoto2 も同じ補正をしている（library.c: Manufacturer に "Nikon" があれば Nikon とみなす）
        if vendor == 0x6 || vendor == 0xFFFF_FFFF || vendor == 0 {
            if info.manufacturer.localizedCaseInsensitiveContains("Nikon") { vendor = PropFormat.vendorNikon }
            else if info.manufacturer.localizedCaseInsensitiveContains("Sony") { vendor = PropFormat.vendorSony }
        }
        DebugLog.write(String(format: "メーカー 0x%08X（名乗り 0x%08X / %@）", vendor, info.vendor, info.manufacturer))
        if PropFormat.vendor != vendor {
            PropFormat.vendor = vendor
            DebugLog.write(String(format: "メーカー 0x%08X", vendor))
            objectWillChange.send()
        }
    }

    /// PTP の DeviceInfo。
    ///   uint16 規格版 / uint32 VendorExtensionID / uint16 拡張版 / 文字列 拡張説明 / uint16 機能モード /
    ///   配列×5（命令・イベント・属性・撮影形式・画像形式）/ 文字列 メーカー名 / 文字列 機種名 / …
    struct DeviceInfo {
        let vendor: UInt32
        let manufacturer: String
        let model: String
        let operations: [UInt16]
        let events: [UInt16]
        let properties: [UInt16]
    }

    private static func parseDeviceInfo(_ data: Data) -> DeviceInfo? {
        let b = [UInt8](data)
        var i = 0
        func u16() -> UInt16? { guard i + 2 <= b.count else { return nil }; defer { i += 2 }; return UInt16(b[i]) | UInt16(b[i + 1]) << 8 }
        func u32() -> UInt32? {
            guard i + 4 <= b.count else { return nil }; defer { i += 4 }
            return UInt32(b[i]) | UInt32(b[i + 1]) << 8 | UInt32(b[i + 2]) << 16 | UInt32(b[i + 3]) << 24
        }
        func string() -> String? {
            guard i < b.count else { return nil }
            let n = Int(b[i]); i += 1
            guard i + n * 2 <= b.count else { return nil }
            let units = (0..<n).map { UInt16(b[i + 2 * $0]) | UInt16(b[i + 2 * $0 + 1]) << 8 }.filter { $0 != 0 }
            i += n * 2
            return String(decoding: units, as: UTF16.self)
        }
        func array16() -> [UInt16]? {
            guard let n = u32(), i + Int(n) * 2 <= b.count else { return nil }
            return (0..<Int(n)).compactMap { _ in u16() }
        }
        guard u16() != nil, let vendor = u32(), u16() != nil, string() != nil, u16() != nil,
              let operations = array16(), let events = array16(), let properties = array16(),
              array16() != nil, array16() != nil,
              let manufacturer = string() else { return nil }
        return DeviceInfo(vendor: vendor, manufacturer: manufacturer, model: string() ?? "",
                          operations: operations, events: events, properties: properties)
    }

    /// カメラが対応を名乗っているプロパティ（DeviceInfo）
    private var supportedProperties: [UInt16] = []
    #if DEBUG
    private var dumpedProperties = false

    /// 調査用。対応しているプロパティの値をすべてログに残す（起動ごとに 1 回）。
    /// 電池残量は 0x5001 が 20% 刻みでしか返らない（本体メニュー 42% のとき 60）ので、
    /// 1% 単位の残量を持つプロパティが他にないか探す。載っている 206 件には無かった
    private func dumpPropertyValuesOnce() async {
        guard !dumpedProperties, !supportedProperties.isEmpty else { return }
        dumpedProperties = true
        var all = supportedProperties
        if capabilities?.isNikon1 == true {
            // Nikon 1 は独自プロパティを 0xF000 番台に持つ（libgphoto2 は J5 で 0xF01C まで確認）
            all += (0xF000...0xF01C).map { UInt16($0) }.filter { !supportedProperties.contains($0) }
        }
        if let d = try? await send(.nikonGetVendorPropCodes) {
            // uint32 個数 → uint16 の並び
            let b = [UInt8](d)
            if b.count >= 4 {
                let n = Int(UInt32(b[0]) | UInt32(b[1]) << 8 | UInt32(b[2]) << 16 | UInt32(b[3]) << 24)
                for k in 0..<n where 4 + 2 * k + 1 < b.count {
                    all.append(UInt16(b[4 + 2 * k]) | UInt16(b[5 + 2 * k]) << 8)
                }
            }
        }
        DebugLog.write("プロパティ値: 標準 \(supportedProperties.count) 件 + 独自 \(all.count - supportedProperties.count) 件")
        var line: [String] = []
        func flush() {
            if !line.isEmpty { DebugLog.write("プロパティ値: " + line.joined(separator: " ")) }
            line = []
        }
        for prop in all {
            guard isConnected else { return }
            line.append(String(format: "%04X=", prop) + (await propertyValueText(prop) ?? "×"))
            if line.count == 12 { flush() }
        }
        flush()

        // 一覧に載っていない番号も読むだけ試す（読み取りのみで設定は変わらない）。
        // 本体メニューの電池残量（1% 単位）が隠れていないかを見るため。1 回やれば十分なので覚えておく
        let scanKey = "unlistedPropertyScan.v1"
        guard !UserDefaults.standard.bool(forKey: scanKey) else { return }
        let listed = Set(all)
        let candidates = Array(0x5000...0x50FF) + Array(0xD000...0xD4FF)
        let started = Date()
        var found = 0
        DebugLog.write("未掲載プロパティの走査を開始（\(candidates.count) 件）")
        for code in candidates.map({ UInt16($0) }) where !listed.contains(code) {
            guard isConnected else { return }
            if let text = await propertyValueText(code) {
                found += 1
                line.append(String(format: "%04X=", code) + text)
                if line.count == 12 { flush() }
            }
        }
        flush()
        UserDefaults.standard.set(true, forKey: scanKey)
        DebugLog.write(String(format: "未掲載プロパティの走査を終了: 応答 %d 件、%.1f 秒", found, Date().timeIntervalSince(started)))
    }

    private func propertyValueText(_ prop: UInt16) async -> String? {
        guard let d = try? await send(.getDevicePropValue, params: [UInt32(prop)]) else { return nil }
        let b = [UInt8](d)
        if [1, 2, 4].contains(b.count) {
            return "\(b.enumerated().reduce(UInt32(0)) { $0 | UInt32($1.element) << (8 * $1.offset) })"
        } else if b.count <= 24 {
            return b.map { String(format: "%02X", $0) }.joined()
        }
        return "(\(b.count)B)"
    }
    #endif

    /// 接続時点のオブジェクト数を数えて、次回の目安として覚えておく
    private func countObjects() async {
        guard expectedObjects == nil,
              let data = try? await send(.getObjectHandles, params: [0xFFFF_FFFF, 0, 0]) else { return }
        var r = PTPReader(data)
        guard let n = r.read(UInt32.self) else { return }
        expectedObjects = Int(n)
        if let id = lastCameraID { UserDefaults.standard.set(Int(n), forKey: "cardObjects.\(id)") }
        DebugLog.write("カード内のオブジェクト \(n) 件")
    }

    /// 接続後に撮られたカットか。
    ///
    /// 時計を合わせる前に撮られたカットはカメラの時計のまま、合わせた後は端末の時計で記録される。
    /// カメラが遅れていた場合は、接続時点のカメラ時刻まで基準を下げれば両方拾える。
    /// 進んでいた場合は、合わせた後のカットが基準を下回らないよう端末時刻を基準にする。
    private func isShotAfterConnecting(_ file: ICCameraFile) -> Bool {
        guard let taken = file.creationDate, let since = connectedAt else { return catalogReady }
        let cutoff = since.addingTimeInterval(-max(clockDrift ?? 0, 0) - 2)
        return taken >= cutoff
    }

    /// 撮影時刻にいちばん近い撮影通知。
    ///
    /// 以前は通知とカットを 1 対 1 で使い切っていた（取り出した通知とそれより古い通知を捨てる）。
    /// 連写では通知がカードに書き終えた順に数秒ずつ遅れて届くので、後ろのコマほど許容幅から外れて相手が無くなり、
    /// 位置が抜けたり、後から取れた精密な位置が 1 枚にしか入らなかったりした。
    /// 数秒の間に撮ったカットは同じ場所なので、通知は何枚で共有してもよい。
    ///
    /// いちばん近い通知（nearest）と、位置を持つ中でいちばん近い通知（located）を返す。
    /// nearest にまだ位置が無ければ、located の位置で仮に並べ、nearest に位置が届いたら差し替える。
    /// 歩きながら撮ったときに、少し前のカットの位置で確定させてしまわないため
    private func shotEvents(near taken: Date) -> (nearest: ShotEvent?, located: ShotEvent?) {
        // 通知はカードへの書き込みが終わってから届く。連写の後ろのコマはバッファの書き出し待ちで十数秒遅れうる
        let tolerance = abs(clockDrift ?? 0) + 20
        let candidates = shotEvents.filter { abs($0.time.timeIntervalSince(taken)) <= tolerance }
        func distance(_ e: ShotEvent) -> TimeInterval { abs(e.time.timeIntervalSince(taken)) }
        return (candidates.min { distance($0) < distance($1) },
                candidates.filter { $0.location != nil }.min { distance($0) < distance($1) })
    }

    /// カード内のカット（つなぐ前に撮ったもの）の撮影地点を、端末の記録から探す。
    ///
    /// 1. 以前テザーで届いたときに控えた位置（同じファイル名で、撮影時刻が近いものだけ。番号は一巡するので）
    /// 2. 軌跡から撮影時刻で見積もる。つなぐ前のカメラ時計は合わせる前なので、接続時に読んだずれを足す
    private func cardLocation(for shot: Shot) -> CLLocation? {
        guard let captured = shot.captured else { return nil }
        let time = captured.addingTimeInterval(clockDrift ?? 0)
        if let known = geoLog.shots[shot.name], abs(known.time.timeIntervalSince(time)) <= 10 * 60 {
            return known.location(at: captured)
        }
        return geoLog.estimateLocation(at: time).map {
            CLLocation(coordinate: $0.coordinate, altitude: $0.altitude, horizontalAccuracy: $0.horizontalAccuracy,
                       verticalAccuracy: $0.verticalAccuracy, timestamp: captured)
        }
    }

    /// 届いたファイルを一覧に振り分ける
    private func ingest(_ files: [ICCameraFile]) {
        guard !files.isEmpty else { return }
        var listed = Set(liveShots.map(\.name)).union(cardShots.map(\.name))
        var live: [(Shot, ICCameraFile)] = []
        var card: [Shot] = []
        for file in files {
            guard let name = file.name else { continue }
            // 開き直しや挿し直しでは、同じファイルが別のオブジェクトで届き直す。参照は新しい方へ
            fileIndex[name] = file
            guard !listed.contains(name) else { continue }
            listed.insert(name)
            let shot = Shot(name: name, size: Int(file.fileSize), captured: file.creationDate)
            if isShotAfterConnecting(file) { live.append((shot, file)) } else { card.append(shot) }
        }

        if !live.isEmpty {
            // 撮影通知は古い順に溜まっているので、カットも撮影順に並べてから対応づける
            live.sort { ($0.0.captured ?? .distantPast) < ($1.0.captured ?? .distantPast) }
            var added: [Shot] = []
            for (var shot, _) in live {
                if geotagging {
                    let (event, located) = shot.captured.map { shotEvents(near: $0) } ?? (nil, nil)
                    // 精密な位置がまだ取れていなければ、取れたときにこのカットへ入れる
                    if let event, event.location == nil { provisionalShots[shot.name] = event.id }
                    let here = event?.location
                        ?? located?.location
                        ?? geoLog.shots[shot.name]?.location
                        ?? shot.captured.flatMap { geoLog.estimateLocation(at: $0) }
                        ?? location.current
                    if let here {
                        shot.location = here
                        if geoLog.shots[shot.name] == nil { geoLog.recordShot(shot.name, at: here) }
                    }
                    DebugLog.write("テザー側: \(shot.name) 撮影 \(shot.captured.map { "\($0)" } ?? "?") 位置の出どころ=\(event?.location != nil ? "撮影通知" : located != nil ? "近くの撮影通知" : here == nil ? "なし" : "軌跡か現在地")\(provisionalShots[shot.name] != nil ? "（精密な位置待ち）" : "")")
                } else {
                    DebugLog.write("テザー側: \(shot.name)")
                }
                added.append(shot)
            }
            liveShots.insert(contentsOf: added.reversed(), at: 0)
            Haptics.shotArrived()
            selection = liveShots.first?.id
            for shot in added { requestThumbnail(for: shot) }
            if pocketed {
                shotsWhilePocketed += added.count
                schedulePrefetch()
            }
        }
        if !card.isEmpty {
            if geotagging {
                for i in card.indices { card[i].location = cardLocation(for: card[i]) }
            }
            cardShots.append(contentsOf: card)
            if catalogReady { cardShots.sort { $0.name > $1.name } }
        }
    }

    /// 完了の合図のあと、ファイルの到着が 1.5 秒途切れたら完了とみなす。
    /// 抜き差し直後は合図が先走り、その後もファイルが 0.1 秒おきに届き続けるため。
    private func scheduleCatalogSettle() {
        guard frameworkCatalogDone, !catalogReady, classifyReady else { return }
        catalogSettle?.cancel()
        catalogSettle = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(1500))
            guard !Task.isCancelled else { return }
            self?.finishCatalog()
        }
    }

    private func finishCatalog() {
        guard !catalogReady else { return }
        // 挿し直しの間にカードが替わっていたら、もう無いカットを外す（取り込み済みは残す）。
        // 完了の判定が早すぎた場合に、まだ届いていないだけのカットを消さないよう、
        // 届いた数が接続時のオブジェクト数にほぼ達しているときに限る（フォルダの分は見逃す）
        if let expected = expectedObjects, deliveredNames.count + 10 >= expected {
            liveShots.removeAll { fileIndex[$0.name] == nil && $0.localURL == nil }
            cardShots.removeAll { fileIndex[$0.name] == nil && $0.localURL == nil }
        }
        cardShots.sort { $0.name > $1.name }
        catalogReady = true
        catalogProgress = 100
        progressTimer?.invalidate()
        DebugLog.write("読み込み完了: テザー \(liveShots.count) / カード \(cardShots.count)")
        #if DEBUG
        logCardLocationCoverage()
        #endif
    }

    #if DEBUG
    /// 調査用。カード側のカットに位置が付いたか、付かなかったのはいつ撮ったものか。
    /// 付かなかったカットは撮影時刻で固まりにまとめ、軌跡のいちばん近い点までの時間を添える
    private func logCardLocationCoverage() {
        guard geotagging, let first = geoLog.track.first?.time, let last = geoLog.track.last?.time else { return }
        let shots = cardShots.compactMap { shot in shot.captured.map { (shot, $0.addingTimeInterval(clockDrift ?? 0)) } }
            .sorted { $0.1 < $1.1 }
        let inRange = shots.filter { $0.1 >= first.addingTimeInterval(-120) && $0.1 <= last.addingTimeInterval(120) }
        let located = inRange.filter { $0.0.location != nil }.count
        DebugLog.write("カード側の位置: 軌跡の期間内 \(inRange.count) 件中 \(located) 件に付いた（期間外 \(shots.count - inRange.count) 件）")
        let f = DateFormatter()
        f.dateFormat = "MM/dd HH:mm:ss"
        var runs: [(from: Shot, fromTime: Date, to: Shot, toTime: Date, count: Int)] = []
        for (shot, time) in inRange where shot.location == nil {
            if let lastRun = runs.last, time.timeIntervalSince(lastRun.toTime) < 60 {
                runs[runs.count - 1] = (lastRun.from, lastRun.fromTime, shot, time, lastRun.count + 1)
            } else {
                runs.append((shot, time, shot, time, 1))
            }
        }
        for run in runs.prefix(20) {
            let nearest = geoLog.track.map { abs($0.time.timeIntervalSince(run.fromTime)) }.min() ?? 0
            DebugLog.write("  付かなかった: \(f.string(from: run.fromTime))〜\(f.string(from: run.toTime)) \(run.count) 件 "
                           + "(\(run.from.name)〜\(run.to.name)) 軌跡の最寄り点まで \(Int(nearest / 60)) 分")
        }
        // 付いた固まりの中に、付かなかったカットが挟まっていないか（連写の虫食い）
        var holes = 0
        for i in inRange.indices.dropFirst().dropLast() where inRange[i].0.location == nil
            && inRange[i - 1].0.location != nil && inRange[i + 1].0.location != nil
            && inRange[i + 1].1.timeIntervalSince(inRange[i - 1].1) < 60 {
            holes += 1
            DebugLog.write("  虫食い: \(inRange[i].0.name) \(f.string(from: inRange[i].1))")
        }
        DebugLog.write("カード側の位置: 前後が付いているのに抜けたカット \(holes) 件")
    }
    #endif

    /// 抜かれたカメラの後始末。挿し直すとオブジェクトが作り直されるので、それに紐づく状態は捨てる。
    /// カットの一覧は残す。うっかりケーブルが抜けても、同じカメラなら続きから使えるように。
    private func forgetDevice() {
        UserDefaults.standard.set(Date(), forKey: "lastSessionEnded")
        live.forget()
        userDisconnected = false
        capabilities = nil
        refusalsLogged = []
        camera = nil
        fileIndex = [:]
        connectedAt = nil
        clockDrift = nil
        classifyReady = false
        pendingFiles = []
        expectedObjects = nil
        deliveredNames = []
        shotEvents = []
        provisionalShots = [:]
        deferredThumbnails = []
        prefetchTask?.cancel()
        preparing = false
        frameworkCatalogDone = false
        catalogSettle?.cancel()
        catalogReady = false
        catalogProgress = 0
        closedForBackground = false
        reopenAfterClose = false
        thumbnailRequested = []
        previewRequested = []
        progressTimer?.invalidate()
        eventLoop?.cancel()
        transferCount = 0
        lightMeter = nil
        props = [:]
        geoLog.save()
        DebugLog.write("カメラが外れた")
    }

    /// カメラの内蔵時計を端末に合わせる。
    ///
    /// 接続のたびに黙って行う。時計がずれていると撮影ファイルの
    /// EXIF 時刻が全部ずれ、あとから位置情報を時刻で突き合わせる際にも
    /// そのまま誤差になる。手で押させる理由がない。
    private func syncClock() async {
        guard let data = try? await send(.getDevicePropValue, params: [PTP.dateTimeProp]),
              let text = PTP.decodeString(data) else { return }

        let parser = DateFormatter()
        parser.dateFormat = "yyyyMMdd'T'HHmmss"
        parser.timeZone = .current
        // 機種によって ".0" や "Z" が付くので、先頭 15 文字だけ見る
        let head = String(text.prefix(15))
        guard let cameraTime = parser.date(from: head) else { return }

        let drift = Date().timeIntervalSince(cameraTime)
        // 撮影時刻での判定に使うので、このカメラで最初に読んだずれを覚えておく
        if clockDrift == nil { clockDrift = drift }
        guard abs(drift) > 2 else { return }   // 誤差の範囲なら触らない

        let now = parser.string(from: Date())
        guard (try? await send(.setDevicePropValue,
                               params: [PTP.dateTimeProp],
                               outData: PTP.encodeString(now))) != nil else { return }
        clockCorrection = drift
    }

    /// カメラ側の変化を拾う。
    ///
    /// Nikon は変更を勝手に送ってこないので、こちらから聞きに行く必要がある。
    /// libgphoto2 も内部で同じことをしている。
    /// CheckEvent は「何が変わったか」を 1 回の往復でまとめて返すので、
    /// プロパティを個別に叩くより無駄が少ない。
    /// 本体側で絞りや ISO を回したときの追従もこれで効く。
    private func startEventPolling() {
        eventLoop?.cancel()
        eventLoop = Task { [weak self] in await self?.runEventLoop() }
    }

    /// 変化が続いている間は細かく、静かになったら間隔を空ける。
    ///
    /// 常に速く叩き続ける必要はない。露出計が動いているのは
    /// 利用者がカメラを構えている最中だけで、放置している間は
    /// 何も変わらない。変化を検知したらすぐ元の速さに戻す。
    private func runEventLoop() async {
        var quiet = 0
        var blockedSince: Date?
        var reportedBlock = false
        DebugLog.write("露出計の問い合わせを開始")
        while !Task.isCancelled {
            let interval: Duration =
                quiet > 12 ? .milliseconds(2000) :
                quiet > 4  ? .milliseconds(900)  :
                             .milliseconds(350)
            try? await Task.sleep(for: interval)

            guard isConnected else {
                DebugLog.write("露出計の問い合わせを終了（未接続）")
                return
            }
            // 画面が見えていない、撮影中、転送中は叩かない
            let blockers = [suspended ? "画面外" : nil, pocketed ? "ポケット" : nil,
                            busy ? "撮影中" : nil, transferCount > 0 ? "転送中\(transferCount)" : nil].compactMap { $0 }
            if !blockers.isEmpty {
                // 止まっている理由が長く続いたら残す。止まったまま戻らない不具合を追うため
                if blockedSince == nil { blockedSince = Date() }
                if !reportedBlock, let since = blockedSince, Date().timeIntervalSince(since) > 8 {
                    DebugLog.write("露出計の問い合わせを止めている: \(blockers.joined(separator: "・"))")
                    reportedBlock = true
                }
                continue
            }
            if reportedBlock { DebugLog.write("露出計の問い合わせを再開") }
            blockedSince = nil
            reportedBlock = false

            let changed = await pollOnce()
            quiet = changed ? 0 : quiet + 1
        }
    }


    /// 露出計が画面に出ていないときは止める。
    /// 全画面プレビュー中やアプリが背面に回っている間がこれにあたる。
    func setPollingSuspended(_ value: Bool) {
        guard suspended != value else { return }
        suspended = value
    }

    /// 変化があったかどうかを返す。呼び出し側が間隔の調整に使う。
    private func pollOnce() async -> Bool {
        guard checkEventUsable else {
            let before = lightMeter
            await readLightMeter()
            return before != lightMeter
        }
        let data: Data
        do {
            data = try await send(.nikonCheckEvent)
        } catch CameraError.ptp(0x2005) {
            // OperationNotSupported。対応していない機種だった。以後は露出計だけ直接読む
            checkEventUsable = false
            DebugLog.write("CheckEvent 非対応。露出計を直接読む方式に切り替え")
            return false
        } catch {
            // ビジーやセッションの開け閉めと重なっただけ。次の回にまた聞く。
            // 以前はここでも諦めていたため、一度の失敗で露出計が止まったままになっていた
            DebugLog.write("CheckEvent 失敗（次回また試す）: \(describe(error))")
            return false
        }
        #if DEBUG
        // 設定の変化以外（SDRAM への撮影 0xC101/0xC102、ライブビューの状態 0xC10C など）は調べるために残す
        let others = Self.otherEvents(in: data)
        if !others.isEmpty { DebugLog.write("CheckEvent: " + others.joined(separator: " ")) }
        #endif
        let changed = Self.changedProperties(in: data)
        guard !changed.isEmpty else { return false }

        if changed.contains(UInt16(Self.lightMeterProp)) {
            await readLightMeter()
        }
        // 露出まわりが動いたら、変わった設定だけ読み直す。
        // A モードで半押しするとシャッタースピードが刻々と変わるので、そのたびに全部読むと往復がかさむ。
        // 撮影モードが変わったときは書き込み可否がまとめて変わるので全部読む
        if changed.contains(PTP.Prop.exposureProgram.rawValue) {
            await refreshProps()
        } else {
            for prop in PTP.Prop.allCases where changed.contains(prop.rawValue) {
                await refreshProp(prop)
            }
        }
        return true
    }

    /// CheckEvent の返り値: uint16 個数 → (uint16 イベント, uint32 引数) の並び。
    /// DevicePropChanged (0x4006) の引数が、変わったプロパティのコード。
    private static func changedProperties(in data: Data) -> Set<UInt16> {
        var r = PTPReader(data)
        guard let count = r.read(UInt16.self), count < 256 else { return [] }
        var result: Set<UInt16> = []
        for _ in 0..<count {
            guard let code = r.read(UInt16.self), let param = r.read(UInt32.self) else { break }
            if code == 0x4006 { result.insert(UInt16(truncatingIfNeeded: param)) }
        }
        return result
    }

    private static func otherEvents(in data: Data) -> [String] {
        var r = PTPReader(data)
        guard let count = r.read(UInt16.self), count < 256 else { return [] }
        var result: [String] = []
        for _ in 0..<count {
            guard let code = r.read(UInt16.self), let param = r.read(UInt32.self) else { break }
            if code != 0x4006 { result.append(String(format: "0x%04X(0x%X)", code, param)) }
        }
        return result
    }

    private func readLightMeter() async {
        guard let data = try? await send(.getDevicePropValue, params: [Self.lightMeterProp]) else { return }
        lightMeter = Self.decodeMeter(data)
    }

    /// 幅が機種によって違うので、返ってきたバイト数で解釈する
    private static func decodeMeter(_ data: Data) -> Double? {
        var r = PTPReader(data)
        let raw: Int64?
        switch data.count {
        case 1: raw = r.read(Int8.self).map(Int64.init)
        case 2: raw = r.read(Int16.self).map(Int64.init)
        case 4: raw = r.read(Int32.self).map(Int64.init)
        default: return nil
        }
        guard let raw else { return nil }
        return Double(raw) / 6.0   // 1/6 EV 刻み
    }

    /// カタログ読み込みの進捗を拾って画面に出す。
    /// 何も出ないと「固まった」ように見えるため。
    /// フレームワークの百分率は挿し直し後に先走るので、接続時のオブジェクト数に対する到着数で数える。
    private func startProgressWatch() {
        progressTimer?.invalidate()
        progressTimer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { [weak self] timer in
            Task { @MainActor in
                guard let self, let cam = self.camera, !self.catalogReady else { timer.invalidate(); return }
                if let expected = self.expectedObjects, expected > 0 {
                    self.catalogProgress = min(99, self.deliveredNames.count * 100 / expected)
                } else {
                    self.catalogProgress = min(99, Int(cam.contentCatalogPercentCompleted))
                }
            }
        }
    }

    // MARK: PTP

    /// 生の PTP コマンドを送り、応答データを返す。
    @discardableResult
    func send(_ op: PTP.Op, params: [UInt32] = [], outData: Data? = nil) async throws -> Data {
        guard let cam = camera else { throw CameraError.notConnected }
        // 「読めていて、通してよい」と「まだ読めていない」を取り違えないよう分けて判定する。
        // `capabilities?.refusal(...) ?? 読む前の判定` と書くと、通してよいときの nil まで読む前扱いになり、
        // D300 の独自命令が全部止まってライブビューも露出計も死んだ
        let refusal: (reason: String, code: UInt16)?
        if let caps = capabilities {
            refusal = caps.refusal(op, params: params)
        } else {
            refusal = CameraCapabilities.refusalBeforeDeviceInfo(op, params: params)
        }
        if let refusal {
            // 送らずに断る。Nikon 1 は名乗っていない命令や一部の独自命令で通信ごと固まる
            let key = "\(op.rawValue)-\(params.first ?? 0)"
            if !refusalsLogged.contains(key) {
                refusalsLogged.insert(key)
                DebugLog.write(String(format: "送らなかった 0x%04X%@: %@", op.rawValue,
                                      params.first.map { String(format: "(0x%X)", $0) } ?? "", refusal.reason))
            }
            throw CameraError.ptp(refusal.code)
        }
        let label = String(format: "0x%04X", op.rawValue)
        let started = Date()
        let watchdog = Task {
            try? await Task.sleep(for: .seconds(45))
            guard !Task.isCancelled else { return }
            DebugLog.write("PTP \(label) が45秒返らない（転送中\(transferCount)）")
        }
        defer {
            watchdog.cancel()
            let t = Date().timeIntervalSince(started)
            if t > 45 { DebugLog.write(String(format: "PTP %@ がようやく返った（%.0f秒）", label, t)) }
        }
        return try await withCheckedThrowingContinuation { cont in
            cam.requestSendPTPCommand(PTP.command(op, params: params), outData: outData) { data, response, error in
                if let error {
                    cont.resume(throwing: error)
                    return
                }
                let code = PTP.responseCode(response)
                guard code == 0x2001 else {
                    cont.resume(throwing: CameraError.ptp(code))
                    return
                }
                cont.resume(returning: data)
            }
        }
    }

    /// 設定の現在値と選択肢をまとめて読み直す
    func refreshProps() async {
        guard isConnected else { return }
        var updated: [PTP.Prop: PropDesc] = [:]
        for prop in PTP.Prop.allCases {
            guard let data = try? await send(.getDevicePropDesc, params: [UInt32(prop.rawValue)]),
                  let desc = PropDesc(data) else { continue }
            updated[prop] = desc
        }
        #if DEBUG
        if props[.nikonExposureTime] == nil, let shutter = updated[.nikonExposureTime] {
            DebugLog.write("Nikon シャッタースピード 0xD100 の選択肢: " + shutter.choices.map {
                String(format: "%d/%d→", Int($0 >> 16), Int($0 & 0xFFFF)) + PropFormat.text(.nikonExposureTime, $0)
            }.joined(separator: " "))
        }
        #endif
        props = updated
    }

    /// 設定を書き換える。データ型に応じた幅で値を渡す必要がある。通ったかを返す。
    ///
    /// 読み直すのは変えた設定だけにする。全部読み直すと 1 回ごとに往復が 8 回増え、
    /// スクラバーの確定が遅れて見える。連動して変わる他の設定（M で絞りを変えたときの露出計など）は
    /// CheckEvent が拾う。撮影モードだけは書き込み可否がまとめて変わるので全部読み直す。
    @discardableResult
    func setProp(_ prop: PTP.Prop, to value: Int64) async -> Bool {
        guard let desc = props[prop] else { return false }
        var payload = Data()
        switch desc.dataType {
        case .int8, .uint8:   payload.appendLE(UInt8(truncatingIfNeeded: value))
        case .int16, .uint16: payload.appendLE(UInt16(truncatingIfNeeded: value))
        case .int32, .uint32: payload.appendLE(UInt32(truncatingIfNeeded: value))
        case .int64, .uint64: payload.appendLE(UInt64(truncatingIfNeeded: value))
        case .string:         return false
        }
        do {
            try await send(.setDevicePropValue, params: [UInt32(prop.rawValue)], outData: payload)
            if prop == .exposureProgram {
                await refreshProps()
            } else {
                await refreshProp(prop)
            }
            return true
        } catch {
            lastError = String(localized: "\(prop.label) を変更できませんでした: \(describe(error))")
            return false
        }
    }

    fileprivate func refreshPropForEvent(_ prop: PTP.Prop) async {
        if prop == .exposureProgram { await refreshProps() } else { await refreshProp(prop) }
    }

    /// 1 つの設定だけ読み直す
    private func refreshProp(_ prop: PTP.Prop) async {
        guard let data = try? await send(.getDevicePropDesc, params: [UInt32(prop.rawValue)]),
              let desc = PropDesc(data) else { return }
        props[prop] = desc
    }

    /// AF を走らせる。実機のシャッター半押しに相当する。
    /// Nikon はコマンド送出後に DeviceReady を問い合わせて完了を待つ作法。
    private func autofocus() async {
        do {
            try await send(.nikonAfDrive)
        } catch {
            // ピントが合わなくても撮影は止めない。
            // AF-C や MF では合焦通知自体が来ないため、
            // ここで弾くと撮れないカメラが出てくる。
            return
        }
        // 合焦してカメラが落ち着くまで待つ。最大 3 秒で打ち切る。
        await waitUntilReady(seconds: 3)
    }

    /// シャッターを切る。撮影後のファイルはイベント経由で一覧に加わる。
    func capture() async {
        guard isConnected, !busy else { return }
        busy = true
        defer { busy = false }
        if live.isActive {
            // ライブビューをいったん止め、記録先をカードに戻してから普段どおりに切る
            await live.whileSuspended { await self.releaseShutter() }
        } else {
            await releaseShutter()
        }
        await refreshProps()
    }

    /// 撮影通知（ObjectAdded）を受けた回数。撮り終えたかどうかの目安
    var shotNotificationCount: Int { nextShotEventID }

    /// 撮影命令を送ってから撮影通知が届くまで待つ上限。
    /// 長秒時ノイズ低減では露光と同じ時間だけ処理が続くので、露光時間の 2 倍に余裕を足す
    var captureWaitSeconds: Double {
        var exposure = 1.0
        if let value = props[.nikonExposureTime]?.current {
            let raw = UInt32(truncatingIfNeeded: value)
            if raw >= 0xFFFF_FFFD {
                exposure = 60                      // バルブ・タイム・x200
            } else if raw & 0xFFFF != 0 {
                exposure = Double(raw >> 16) / Double(raw & 0xFFFF)
            }
        }
        return 15 + exposure * 2
    }

    /// シャッターを切る命令がカメラに受け付けられたかを返す
    @discardableResult
    private func releaseShutter() async -> Bool {
        // レリーズの前に必ず AF を通す。
        // 操作を増やさずに、実機のシャッター全押しと同じ挙動にする。
        // Nikon 1 はまず libgphoto2 で通っている手順（標準の 0x100E だけ）に合わせ、AF 命令は確かめてから使う
        if capabilities?.isNikon1 != true { await autofocus() }
        var attempt = 0
        while true {
            attempt += 1
            do {
                try await send(.initiateCapture, params: [0, 0])
                DebugLog.write("リモートシャッター 0x100E: OK")
                return true
            } catch CameraError.ptp(0x2019) where attempt < 5 {
                // まだ AF やミラーが動いている。libgphoto2 と同じく、落ち着くのを待って同じ命令を送り直す。
                // ここで別の撮影命令に切り替えると、遅れて両方が効いて何度も切れるおそれがある
                DebugLog.write("リモートシャッター 0x100E: DeviceBusy（待って送り直す）")
                await waitUntilReady(seconds: 2)
            } catch CameraError.ptp(0x2019) {
                DebugLog.write("リモートシャッター 0x100E: DeviceBusy が続いたので諦める")
                lastError = String(localized: "撮影できませんでした: \(describe(CameraError.ptp(0x2019)))")
                return false
            } catch {
                DebugLog.write("リモートシャッター 0x100E 失敗: \(describe(error))")
                // 標準命令が通らない機種向けに Nikon 独自命令も試す
                do {
                    try await send(.nikonCapture, params: [0xFFFFFFFF])
                    DebugLog.write("リモートシャッター 0x90C0: OK")
                    return true
                } catch {
                    DebugLog.write("リモートシャッター 0x90C0 失敗: \(describe(error))")
                    lastError = String(localized: "撮影できませんでした: \(describe(error))")
                    return false
                }
            }
        }
    }

    /// Nikon の作法で、カメラが次の命令を受けられるようになるまで待つ（libgphoto2 の nikon_wait_busy）。
    /// ビジー以外の応答が返ったら、それが成功でも失敗でも待つのをやめる
    func waitUntilReady(seconds: Double) async {
        guard PropFormat.vendor == PropFormat.vendorNikon else {
            try? await Task.sleep(for: .milliseconds(300))
            return
        }
        let deadline = Date().addingTimeInterval(seconds)
        while isConnected {
            do {
                try await send(.nikonDeviceReady)
                return
            } catch CameraError.ptp(let code) where code == 0x2019 || code == 0xA200 {
                // DeviceBusy / Bulb_Release_Busy
                guard Date() < deadline else { return }
                try? await Task.sleep(for: .milliseconds(100))
            } catch {
                return
            }
        }
    }

    private func describe(_ error: Error) -> String {
        if case CameraError.ptp(let code) = error { return PTP.responseName(code) }
        return error.localizedDescription
    }

    func markDownloaded(_ shot: Shot, url: URL) {
        if let i = liveShots.firstIndex(where: { $0.name == shot.name }) { liveShots[i].localURL = url }
        if let i = cardShots.firstIndex(where: { $0.name == shot.name }) { cardShots[i].localURL = url }
    }

    // MARK: サムネイルと取り込み

    /// 画面に出てきたカットのサムネイルだけを取りに行く。
    /// 一括で要求すると 1 枚ごとに PTP の往復が走り、USB 2.0 が飽和して
    /// 他の操作まで待たされる。表示に必要な分だけ、遅延で取る。
    func requestThumbnail(for shot: Shot) {
        if pocketed {
            deferredThumbnails.insert(shot.name)
            return
        }
        guard shot.thumbnail == nil, !thumbnailRequested.contains(shot.name),
              let file = fileIndex[shot.name] else { return }
        thumbnailRequested.insert(shot.name)
        // 一覧用は小さくてよい。大きく要求すると転送量が増えて一覧の描画が遅れる。
        file.requestThumbnailData(options: [.imageSourceThumbnailMaxPixelSize: 320]) { [weak self] data, _ in
            guard let data, let image = UIImage(data: data) else { return }
            Task { @MainActor in
                guard let self else { return }
                if let i = self.liveShots.firstIndex(where: { $0.name == shot.name }) {
                    self.liveShots[i].thumbnail = image
                }
                if let i = self.cardShots.firstIndex(where: { $0.name == shot.name }) {
                    self.cardShots[i].thumbnail = image
                }
            }
        }
    }

    /// 選択中のカット用に、フル解像度のプレビューを取り寄せる。
    ///
    /// ImageCaptureCore のサムネイル要求は大きいサイズを指定しても
    /// 小さい絵しか返らない。NEF には撮影画像と同画角のフルサイズ JPEG が
    /// 埋め込まれているので、ファイル構造を解析してその範囲だけを読む。
    /// 11MB 全体を落とさずに済む。
    func requestPreview(for shot: Shot) {
        guard shot.preview == nil, let file = fileIndex[shot.name] else { return }
        if previewRequested.contains(shot.name) { return }
        previewRequested.insert(shot.name)

        Task { [weak self] in
            guard let self else { return }
            var image: UIImage?

            // 先頭部分だけ読んで、埋め込み JPEG の位置を割り出す
            if let header = await self.read(file, offset: 0, length: 128 * 1024),
               let loc = NEF.largestPreview(in: header),
               loc.length > 0, loc.length < 40 * 1024 * 1024 {
                if let jpeg = await self.read(file, offset: off_t(loc.offset), length: off_t(loc.length)) {
                    image = UIImage(data: jpeg)
                }
            }
            // 構造を辿れないファイル形式のときは、従来のサムネイル要求に戻す
            if image == nil {
                image = await self.thumbnailData(file, maxPixel: 2400).flatMap(UIImage.init(data:))
            }
            guard let image else { return }

            if let i = self.liveShots.firstIndex(where: { $0.name == shot.name }) {
                self.liveShots[i].preview = image
            }
            if let i = self.cardShots.firstIndex(where: { $0.name == shot.name }) {
                self.cardShots[i].preview = image
            }
        }
    }

    private func read(_ file: ICCameraFile, offset: off_t, length: off_t) async -> Data? {
        transferCount += 1
        defer { transferCount -= 1 }
        let name = file.name ?? "?"
        return await withCheckedContinuation { cont in
            let once = ResumeOnce()
            file.requestReadData(atOffset: offset, length: length) { data, error in
                guard once.claim() else {
                    DebugLog.write("打ち切った読み出しが後から返った: \(name)")
                    return
                }
                if data == nil { DebugLog.write("読み出し失敗: \(name) @\(offset) \(error.map { "\($0)" } ?? "")") }
                cont.resume(returning: data)
            }
            // 1.5MB ほどの埋め込み JPEG でも数秒で終わる。返ってこないものは諦める
            Task {
                try? await Task.sleep(for: .seconds(60))
                guard once.claim() else { return }
                DebugLog.write("読み出しが60秒返らないので打ち切り: \(name) @\(offset) 長さ \(length)")
                cont.resume(returning: nil)
            }
        }
    }

    private func thumbnailData(_ file: ICCameraFile, maxPixel: Int) async -> Data? {
        await withCheckedContinuation { cont in
            file.requestThumbnailData(options: [.imageSourceThumbnailMaxPixelSize: maxPixel]) { data, _ in
                cont.resume(returning: data)
            }
        }
    }

    /// 写真アプリへ保存する。
    /// 取り込み先をアプリ内フォルダだけにすると、利用者からは
    /// 「どこにも入っていない」ように見える。
    func saveToPhotos(_ url: URL, shot: Shot) async -> Bool {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else {
            lastError = String(localized: "写真へのアクセスが許可されていません。設定から許可してください。")
            return false
        }
        do {
            let coordinate = shot.location
            try await PHPhotoLibrary.shared().performChanges {
                let request = PHAssetCreationRequest.forAsset()
                let options = PHAssetResourceCreationOptions()
                options.originalFilename = url.lastPathComponent
                request.addResource(with: .photo, fileURL: url, options: options)
                // RAW 本体には手を触れず、写真アプリの資産情報として位置を持たせる
                if let coordinate { request.location = coordinate }
                if let captured = shot.captured { request.creationDate = captured }
            }
            if let i = liveShots.firstIndex(where: { $0.name == shot.name }) { liveShots[i].savedToPhotos = true }
            if let i = cardShots.firstIndex(where: { $0.name == shot.name }) { cardShots[i].savedToPhotos = true }
            return true
        } catch {
            lastError = String(localized: "写真アプリに保存できませんでした: \(error.localizedDescription)")
            return false
        }
    }

    /// カメラから端末内へ取り込み、そのまま写真アプリへ渡す。
    /// 取り込みの入口。カメラから読み出し、写真アプリへ保存するまでを行う。
    @discardableResult
    func importShot(_ shot: Shot) async -> URL? {
        var shot = shot
        if shot.location == nil, geotagging, !liveShots.contains(where: { $0.name == shot.name }) {
            // 一覧に並べた後に軌跡が増えていることがある（Mac へ送る前の記録など）。取り込む時点でもう一度探す
            shot.location = cardLocation(for: shot)
            if let i = cardShots.firstIndex(where: { $0.name == shot.name }) { cardShots[i].location = shot.location }
        }
        DebugLog.write("取り込み: \(shot.name) 位置 \(shot.location.map { String(format: "%.5f,%.5f ±%.0fm", $0.coordinate.latitude, $0.coordinate.longitude, $0.horizontalAccuracy) } ?? "なし")")
        guard let url = await download(shot) else { return nil }
        markDownloaded(shot, url: url)
        _ = await saveToPhotos(url, shot: shot)
        return url
    }

    private func download(_ shot: Shot) async -> URL? {
        guard let file = fileIndex[shot.name] else { return nil }
        transferCount += 1
        defer { transferCount -= 1 }
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return await withCheckedContinuation { cont in
            file.requestDownload(options: [
                .downloadsDirectoryURL: dir,
                .overwrite: true,
            ]) { filename, error in
                if let error {
                    Task { @MainActor in self.lastError = String(localized: "取り込みに失敗しました: \(error.localizedDescription)") }
                    cont.resume(returning: nil)
                    return
                }
                cont.resume(returning: filename.map { dir.appendingPathComponent($0) })
            }
        }
    }
}

enum CameraError: LocalizedError {
    case notConnected
    case ptp(UInt16)

    var errorDescription: String? {
        switch self {
        case .notConnected: return String(localized: "カメラが接続されていません")
        case .ptp(let code): return String(localized: "カメラが応答しました: \(PTP.responseName(code))")
        }
    }
}

// MARK: - デバイス検出

extension CameraSession: ICDeviceBrowserDelegate {
    nonisolated func deviceBrowser(_ browser: ICDeviceBrowser, didAdd device: ICDevice, moreComing: Bool) {
        Task { @MainActor in
            guard self.camera == nil, let cam = device as? ICCameraDevice else { return }
            let id = cam.uuidString
            if id == nil || id != self.lastCameraID {
                // 別のカメラ。前のカメラの一覧は持ち越さない
                self.liveShots = []
                self.cardShots = []
                self.selection = nil
            }
            self.lastCameraID = id
            self.lastKnownFileCount = id.flatMap { UserDefaults.standard.object(forKey: "cardObjects.\($0)") as? Int }
            self.camera = cam
            cam.delegate = self
            self.state = .connecting(cam.name ?? String(localized: "カメラ"))
            DebugLog.write("カメラを検出: \(cam.name ?? "?") \(id ?? "?")")
            cam.requestOpenSession()
        }
    }

    nonisolated func deviceBrowser(_ browser: ICDeviceBrowser, didRemove device: ICDevice, moreGoing: Bool) {
        Task { @MainActor in
            guard device === self.camera else { return }
            self.forgetDevice()
            Haptics.warning()
            self.state = .failed(String(localized: "カメラが取り外されました"))
        }
    }
}

// MARK: - セッションとファイル

extension CameraSession: ICCameraDeviceDelegate {

    nonisolated func device(_ device: ICDevice, didOpenSessionWithError error: (any Error)?) {
        let opened = Date()
        Task { @MainActor in
            guard device === self.camera else { return }
            if let error {
                self.state = .failed(error.localizedDescription)
                return
            }
            self.state = .connected(device.name ?? String(localized: "カメラ"))
            DebugLog.write("セッションを開いた")
            // つないで初めて開いたときと、手で接続し直したときだけ知らせる。背面から戻るたびには鳴らさない
            let announce = self.connectedAt == nil || self.announceNextOpen
            self.announceNextOpen = false
            if self.connectedAt == nil {
                // このカメラで初めて開いた。ここから準備完了まで命令が通らない
                self.connectedAt = opened
                self.preparing = true
            }
            if !self.catalogReady { self.startProgressWatch() }
            // 何を送ってよいかを先に知る。Nikon 1 は名乗っていない命令を送ると通信ごと固まるので、
            // 時計合わせより前に DeviceInfo を読む（どちらも準備完了まで待たされるのは同じ）
            if self.capabilities == nil { await self.readVendor() }
            // 時計は準備完了まで読めない。読み終えたら、溜めていたファイルを判定して流す
            await self.syncClock()
            self.preparing = false
            if announce, self.isConnected { Haptics.success() }
            if !self.classifyReady {
                self.classifyReady = true
                // 準備の長さは 7 秒台と 38 秒台に分かれ、長いのは前の接続から 10 分以上空いた後に見える。
                // まだ例が少ないので、空いた時間を一緒に残して確かめる
                let gap = (UserDefaults.standard.object(forKey: "lastSessionEnded") as? Date).map { opened.timeIntervalSince($0) / 60 }
                DebugLog.write(String(format: "時計を読んだ（ずれ %.1f 秒）。準備に %.1f 秒（前の接続から %@）",
                                      self.clockDrift ?? 0, Date().timeIntervalSince(opened),
                                      gap.map { String(format: "%.0f 分", $0) } ?? "不明"))
                let held = self.pendingFiles
                self.pendingFiles = []
                self.ingest(held)
            }
            await self.countObjects()
            // 準備完了の直後は DeviceInfo が失敗することがある（J1 の 1 回目の接続で起きた）。
            // 読めないまま進むと独自命令を止められないので、読めるまで何度か試す
            for attempt in 1...4 where self.capabilities == nil && self.isConnected {
                if attempt > 1 { try? await Task.sleep(for: .milliseconds(500)) }
                await self.readVendor()
            }
            if self.supportsLiveView {
                // ライブビュー中にアプリが落ちたりケーブルが抜けたりすると、記録先が SDRAM のまま残り
                // 本体で撮ってもカードに保存されなくなる。つないだら確かめて戻す
                await LiveViewController.restoreIfInterrupted(self)
            }
            self.scheduleCatalogSettle()
            // Nikon 1 の V1・J1 などでは CheckEvent (0x90C7) で通信が壊れる（libgphoto2 #569 #716）。
            // 本体側の変更は USB のイベント（DevicePropChanged）で拾う
            self.checkEventUsable = self.capabilities?.isNikon1 != true
            if self.checkEventUsable || self.lightMeterAvailable {
                self.startEventPolling()
            } else {
                DebugLog.write("CheckEvent と露出計の問い合わせは使わない（Nikon 1）")
            }
            await self.refreshProps()
            #if DEBUG
            await self.dumpPropertyValuesOnce()
            #endif
        }
    }

    nonisolated func device(_ device: ICDevice, didCloseSessionWithError error: (any Error)?) {
        Task { @MainActor in self.sessionDidClose(device) }
    }

    nonisolated func didRemove(_ device: ICDevice) {
        Task { @MainActor in
            guard device === self.camera else { return }
            self.forgetDevice()
            self.state = .idle
        }
    }

    nonisolated func deviceDidBecomeReady(_ device: ICDevice) {
        Task { @MainActor in
            guard device === self.camera else { return }
            self.preparing = false
            DebugLog.write("準備完了")
        }
    }

    nonisolated func cameraDevice(_ camera: ICCameraDevice, didAdd items: [ICCameraItem]) {
        let files = items.compactMap { $0 as? ICCameraFile }
        Task { @MainActor in
            guard camera === self.camera else { return }
            self.deliveredNames.formUnion(files.compactMap(\.name))
            if self.classifyReady {
                self.ingest(files)
            } else {
                self.pendingFiles.append(contentsOf: files)
            }
            self.scheduleCatalogSettle()
        }
    }

    nonisolated func cameraDevice(_ camera: ICCameraDevice, didRemove items: [ICCameraItem]) {}
    nonisolated func cameraDevice(_ camera: ICCameraDevice, didRenameItems items: [ICCameraItem]) {}
    nonisolated func cameraDeviceDidChangeCapability(_ camera: ICCameraDevice) {}
    nonisolated func cameraDevice(_ camera: ICCameraDevice, didReceiveThumbnail thumbnail: CGImage?, for item: ICCameraItem, error: (any Error)?) {}
    nonisolated func cameraDevice(_ camera: ICCameraDevice, didReceiveMetadata metadata: [AnyHashable: Any]?, for item: ICCameraItem, error: (any Error)?) {}
    nonisolated func cameraDeviceDidEnableAccessRestriction(_ device: ICDevice) {}
    nonisolated func cameraDeviceDidRemoveAccessRestriction(_ device: ICDevice) {}

    /// カメラから届く PTP イベント。
    ///   uint32 長さ / uint16 種別 / uint16 コード / uint32 トランザクション / uint32 引数1
    nonisolated func cameraDevice(_ camera: ICCameraDevice, didReceivePTPEvent eventData: Data) {
        let b = [UInt8](eventData)
        guard b.count >= 8 else { return }
        let code = UInt16(b[6]) | UInt16(b[7]) << 8
        let param: UInt32? = b.count >= 16
            ? UInt32(b[12]) | UInt32(b[13]) << 8 | UInt32(b[14]) << 16 | UInt32(b[15]) << 24
            : nil
        Task { @MainActor in
            guard camera === self.camera else { return }
            switch code {
            case 0x4002:
                // ObjectAdded。撮った瞬間に届くので、この時点の位置が撮影地点になる
                let id = self.nextShotEventID
                self.nextShotEventID += 1
                self.shotEvents.append(ShotEvent(id: id, time: Date(), location: nil))
                // 使い切らなくなったので、古いものは時刻で捨てる（カットが届くのは長くても数十秒後）
                let cutoff = Date().addingTimeInterval(-10 * 60)
                self.shotEvents.removeAll { $0.time < cutoff }
                if self.shotEvents.count > 500 { self.shotEvents.removeFirst(self.shotEvents.count - 500) }
                if self.geotagging {
                    // 立ち止まって衛星を止めていれば保持している位置がすぐ返り、無ければ衛星を起こして取る
                    self.location.fixForShot { [weak self] fix in
                        Task { @MainActor in self?.applyShotFix(id: id, fix) }
                    }
                }
                DebugLog.write("撮影通知 handle=\(param.map { String(format: "0x%08X", $0) } ?? "?")")
            case 0x4006:
                // DevicePropChanged。Nikon 1 のように CheckEvent を使えない機種は、本体側の変更をここで拾う
                guard let param, !self.checkEventUsable, !self.pocketed else { return }
                if let prop = PTP.Prop(rawValue: UInt16(truncatingIfNeeded: param)) {
                    await self.refreshPropForEvent(prop)
                }
            case 0x400D:
                // CaptureComplete。撮影直後は設定が変わっていることがあるので読み直す。
                // ポケットの中では誰も見ていないので、取り出したときにまとめて読む
                guard !self.pocketed else { return }
                await self.refreshProps()
            default:
                break
            }
        }
    }

    /// フレームワークが「読み込み完了」と言ってきた。
    /// 挿し直し直後は先走るので、到着が落ち着くまで待ってから完了にする。
    nonisolated func deviceDidBecomeReady(withCompleteContentCatalog device: ICCameraDevice) {
        Task { @MainActor in
            guard device === self.camera else { return }
            DebugLog.write("フレームワークの完了通知（この時点 \(self.deliveredNames.count) 件）")
            self.frameworkCatalogDone = true
            self.scheduleCatalogSettle()
        }
    }
}


/// 完了とタイムアウトのどちらか先に来た方だけを通す
private final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func claim() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !done else { return false }
        done = true
        return true
    }
}


/// DeviceInfo から分かる、このカメラが受け付けるもの。送ってはいけない命令をここで止める。
///
/// Nikon 1（J1 など）は、名乗っていない命令や一部の独自命令を送ると USB の通信ごと固まり、
/// ケーブルを挿し直すまで何も通らなくなる。libgphoto2 の記録:
/// - ChangeCameraMode 0x90C2: J1 が固まる（#716。J1 はこの命令を名乗っていない）
/// - GetEvent 0x90C7: V1・J1・S1・J3・J4 で不安定（#569 #716 #845）
/// - GetVendorPropCodes 0x90CA: V1・J1・J2 で通信が壊れる
/// - InitiateCaptureRecInSdram 0x90C0: V1・J1 で不安定。標準の InitiateCapture 0x100E に置き換えて撮れている
/// D300 など他の機種では、これまで実機で通っている手順を変えないよう止めない
struct CameraCapabilities {
    let model: String
    let operations: Set<UInt16>
    let events: Set<UInt16>
    let properties: Set<UInt16>
    /// libgphoto2 と同じ判定: Nikon で、機種名が J・V で始まるか S1・S2
    let isNikon1: Bool

    private static let nikon1Unsafe: Set<UInt16> = [0x90C2, 0x90C7, 0x90CA, 0x90C0]

    init(_ info: CameraSession.DeviceInfo) {
        model = info.model
        operations = Set(info.operations)
        events = Set(info.events)
        properties = Set(info.properties)
        let nikon = info.manufacturer.localizedCaseInsensitiveContains("Nikon")
        let first = info.model.first
        isNikon1 = nikon && (first == "J" || first == "V" || (first == "S" && info.model.count < 3))
    }

    /// DeviceInfo を読めるまでは機種が分からない。標準の命令と標準のプロパティだけを通す。
    /// J1 の 1 回目の接続で DeviceInfo が失敗し、そのまま CheckEvent を送って 0.2 秒後にカメラが外れた
    static func refusalBeforeDeviceInfo(_ op: PTP.Op, params: [UInt32]) -> (reason: String, code: UInt16)? {
        if op.rawValue >= 0x9000 {
            return ("DeviceInfo を読む前の独自命令", 0x2005)
        }
        if [PTP.Op.getDevicePropDesc, .getDevicePropValue, .setDevicePropValue].contains(op),
           let prop = params.first, prop >= 0xD000 {
            return ("DeviceInfo を読む前の独自プロパティ", 0x200A)
        }
        return nil
    }

    /// 送ってはいけなければ、その理由と代わりに返す応答コード
    func refusal(_ op: PTP.Op, params: [UInt32]) -> (reason: String, code: UInt16)? {
        guard isNikon1 else { return nil }
        let code = op.rawValue
        if Self.nikon1Unsafe.contains(code) {
            return ("Nikon 1 で通信が壊れる命令", 0x2005)
        }
        if code >= 0x9000, !operations.contains(code) {
            return ("カメラが名乗っていない命令", 0x2005)
        }
        if [PTP.Op.getDevicePropDesc, .getDevicePropValue, .setDevicePropValue].contains(op),
           let prop = params.first.map({ UInt16(truncatingIfNeeded: $0) }),
           !properties.contains(prop), !(0xF000...0xF01C).contains(prop) {
            return ("カメラが名乗っていないプロパティ", 0x200A)
        }
        return nil
    }
}
