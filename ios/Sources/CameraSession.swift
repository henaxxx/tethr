import Foundation
import ImageCaptureCore
import TethrKit
import TethrUI
import UIKit
import Photos
import CoreLocation
import Combine

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
        didSet {
            updatePocketWatch()
            switch state {
            case .connecting, .connected:
                if activitySince == nil { activitySince = Date() }
            default:
                activitySince = nil
            }
        }
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
        ExposureLayout.meterMeaningful(in: props) && lightMeterAvailable
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
    /// 取り込み中のカット（ファイル名 → 0〜1）。取り込みボタンがカプセルの中を満たすのに使う
    @Published private(set) var importProgress: [String: Double] = [:]

    private let browser = ICDeviceBrowser()
    private var camera: ICCameraDevice?
    /// 生の PTP 命令の送り先（Mac 版と共通の TethrKit）。カメラを検出したときに作り、外れたら捨てる
    private var ptp: PTPCamera?
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
    /// 背面に回ったあとも、しばらく接続を保っている（読み込みを続け、届いたカットも受ける）
    private var backgroundWatch: Task<Void, Never>?
    /// 背面で接続を保つ期限。ダイナミックアイランドに残り時間を出す
    @Published private(set) var backgroundKeepUntil: Date?
    /// ダイナミックアイランドとロック画面の表示
    private let activity = LiveActivityController()
    /// 選んだカットをまとめて取り込む
    let batch = BatchImporter()
    /// 取り込んだカットの控え（Mac 版と共通の形式）
    private let ledger = ImportLedger(
        url: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("imported.json"),
        log: { DebugLog.write($0) }
    )
    private var activityObservation: AnyCancellable?
    /// 接続を始めた時刻（準備中の経過時間の起点）
    private var activitySince: Date?
    private var eventLoop: Task<Void, Never>?
    /// 画面が見えていない、あるいは露出計が出ていない間は問い合わせない
    private var suspended = false
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
    #if DEBUG
    /// カメラ無しで画面を確かめるための、つながったふりの状態（起動引数 -demo）
    private(set) var demo = false
    /// デモでまだ届いていないことにしてあるサムネイル。一覧に出たときに少し遅れて入れる
    private var demoPendingThumbnails: [String: UIImage] = [:]
    #endif
    /// ライブビュー。映像は別の観測対象に分けてあり、画面全体は描き直さない
    let live = LiveViewController()
    /// いまつないでいるカメラの識別子。カメラごとの覚え書きに使う
    var cameraIdentifier: String? { lastCameraID }
    private var appActive = true
    private var shotsWhilePocketed = 0
    /// ポケットの中で取らずにおいたサムネイル
    private var deferredThumbnails: Set<String> = []
    private var prefetchTask: Task<Void, Never>?

    /// スクラバーで操作する設定（撮影モードで入れ替わる。規則は TethrKit の ExposureLayout）
    var adjustable: [PTP.Prop] { ExposureLayout.adjustable(in: props) }

    /// カメラ任せになっている露出の値（A モードのシャッターなど）。スクラバーの上に数字だけ出す
    var cameraDecided: [PTP.Prop] { ExposureLayout.cameraDecided(in: props) }

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
        location.lastRecordedTime = { [weak self] in self?.geoLog.track.last?.time }
        location.onModeChange = { [weak self] mode in
            Task { @MainActor in self?.gpsMode = mode }
        }
        pocketModeEnabled = UserDefaults.standard.object(forKey: "pocketMode") as? Bool ?? true
        pocket.onChange = { [weak self] value in self?.pocketChanged(value) }
        live.session = self
        // 画面に出している状態が変わったら、ダイナミックアイランドにも反映する（細かい変化はまとめる）
        batch.session = self
        ImportFiles.cleanUp()
        activityObservation = objectWillChange.merge(with: batch.objectWillChange)
            .throttle(for: .milliseconds(800), scheduler: RunLoop.main, latest: true)
            .sink { [weak self] _ in self?.refreshActivity() }
    }

    /// 前面にいるか
    var isAppActive: Bool { appActive }

    /// テザーとカードのどちらかにある、その名前のカット
    func shot(named name: String) -> Shot? {
        liveShots.first { $0.name == name } ?? cardShots.first { $0.name == name }
    }

    /// いま取り込めるか。接続を休ませている間やつなぎ直しの途中、一覧にまだ届いていないカットは取り込めない
    func canImport(_ name: String) -> Bool {
        isConnected && camera?.hasOpenSession == true && fileIndex[name] != nil
    }

    private func updatePocketWatch() {
        pocket.active = pocketModeEnabled && isConnected && appActive
    }

    private func pocketChanged(_ value: Bool) {
        pocketed = value
        // 取り出すと自動ロックが戻るが、まとめて取り込んでいる間は画面を消さない
        if batch.isRunning { UIApplication.shared.isIdleTimerDisabled = true }
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
        let eventTime = shotEvents.first { $0.id == id }?.time ?? Date()
        if let i = shotEvents.firstIndex(where: { $0.id == id }) { shotEvents[i].location = fix }
        // 連写では 1 つの通知を何枚ものカットが借りている。全部に入れる
        for (name, eventID) in provisionalShots where eventID == id {
            provisionalShots[name] = nil
            if let i = liveShots.firstIndex(where: { $0.name == name }) { liveShots[i].location = fix }
            geoLog.recordShot(name, at: fix, time: eventTime)
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

    /// ライブビューを出せるか。Nikon 1 はまだ手順を確かめていない（J1 は開始命令自体を名乗っていない）
    var supportsLiveView: Bool {
        PropFormat.vendor == PropFormat.vendorNikon && capabilities?.isNikon1 != true
    }

    /// DeviceInfo に露出まわりの設定が 1 つも載っていない（J1 は電池と時計だけ）
    var cannotAdjustSettings: Bool {
        guard isConnected, let caps = capabilities else { return false }
        // 画質・焦点距離・フォーカスモードは見るだけの項目なので数えない
        let exposure: [PTP.Prop] = [.exposureProgram, .exposureTime, .nikonExposureTime, .fNumber, .iso, .exposureBias, .whiteBalance]
        return !exposure.contains { caps.properties.contains($0.rawValue) }
    }

    /// 露出計（Nikon 0xD1B1）を読めるか
    var lightMeterAvailable: Bool {
        guard let caps = capabilities, caps.isNikon1 else { return true }
        return caps.properties.contains(UInt16(PTPCamera.lightMeterCode))
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
        // 背面に回ったあとは予告なく終了させられることがある。控えた位置と取り込みの控えをここで書き出しておく
        geoLog.save()
        ledger.flush()
        guard let cam = camera, cam.hasOpenSession else { return }
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "camera-session") { [weak self] in
            Task { @MainActor in self?.backgroundTimeExpired() }
        }
        Task {
            // ライブビューは誰も見ていないので止める。止める命令を省くとミラーが上がったまま残り、
            // 記録先も SDRAM のままになってカードに保存されなくなる
            if live.isActive { await live.stop(reason: "背面へ") }
            keepSessionInBackground(cam)
        }
    }

    /// 背面に回っても、すぐにはセッションを閉じない。
    ///
    /// 以前は背面に回った瞬間に閉じていた（開いたまま iOS に止められると、カメラ側に接続が半開きで残り、
    /// 次の接続で 20〜36 秒待たされるため）。それだと接続の準備やカードの読み込みも止まるので、
    /// 猶予のうちは続け、ダイナミックアイランドに進み具合と残り時間を出す。
    ///
    /// 保つのは最長でも約 30 秒。D300 と iPhone 15 Pro で確かめたところ、
    /// - iOS が背面で許す猶予は約 30 秒。止められる 8 秒前には行儀よく閉じる
    /// - 背面でも位置の記録でアプリが動き続けているときでも、背面に回って約 30 秒たつと
    ///   ImageCaptureCore は一覧のファイルも撮影通知も届けなくなる（読み込みは 463 件中 413 件で止まり、
    ///   2 分後と 3 分半後に撮った 2 枚も届かなかった）。前面に戻ると、溜まっていた分がまとめて届く。
    ///   それ以上保っても電池を食うだけなので、位置の記録中でも 30 秒で閉じる
    private func keepSessionInBackground(_ cam: ICCameraDevice) {
        guard !appActive else {
            endBackgroundTask()
            return
        }
        let entered = Date()
        DebugLog.write("背面へ: 接続を保つ（iOS の猶予 \(Self.describeRemaining())、読み込み\(catalogReady ? "済み" : "中")）")
        // 前面にいた時間が短いと、iOS の猶予が前回の残りのまま（実機で 6 秒）のことがある。待たずにその場で閉じる
        if UIApplication.shared.backgroundTimeRemaining < 10 {
            closeForBackground(cam)
            return
        }
        backgroundWatch?.cancel()
        backgroundWatch = Task { [weak self] in
            var lastReport = entered
            while !Task.isCancelled {
                guard let self, self.camera === cam, cam.hasOpenSession, !self.appActive else { return }
                let now = Date()
                var deadline = entered.addingTimeInterval(28)
                let remaining = UIApplication.shared.backgroundTimeRemaining
                if remaining < 1e6 { deadline = min(deadline, now.addingTimeInterval(remaining - 8)) }
                // iOS 26 で背面でも取り込みを続ける許可が下りていれば、取り込みが進んでいる間は保つ。
                // この許可では backgroundTimeRemaining は 30 秒のまま減っていく（実機）ので、その期限では切らない。
                // 30 秒を超えても ImageCaptureCore が読み出しを続けるかは、開発版のログで確かめる
                if let keep = self.batch.keepSessionUntil { deadline = max(deadline, keep) }
                // 毎秒わずかにずれるので、目に見えるほど変わったときだけ表示を書き換える
                if abs((self.backgroundKeepUntil ?? .distantPast).timeIntervalSince(deadline)) > 2 {
                    self.backgroundKeepUntil = deadline
                }
                if now >= deadline { break }
                #if DEBUG
                if now.timeIntervalSince(lastReport) >= 10 {
                    lastReport = now
                    DebugLog.write("背面 \(Int(now.timeIntervalSince(entered))) 秒: 猶予 \(Self.describeRemaining())、届いたファイル \(self.deliveredNames.count)、テザー \(self.liveShots.count) 枚")
                }
                #endif
                try? await Task.sleep(for: .seconds(1))
            }
            guard let self, !Task.isCancelled, !self.appActive, self.camera === cam else { return }
            self.closeForBackground(cam)
        }
    }

    private static func describeRemaining() -> String {
        let remaining = UIApplication.shared.backgroundTimeRemaining
        return remaining > 1e6 ? "無制限" : String(format: "%.0f 秒", remaining)
    }

    /// 背面で保っていた接続を、行儀よく閉じる。アプリに戻ると開き直す（同じカメラなら 0.1 秒）
    private func closeForBackground(_ cam: ICCameraDevice) {
        backgroundWatch = nil
        backgroundKeepUntil = nil
        guard cam.hasOpenSession, !closedForBackground else {
            endBackgroundTask()
            return
        }
        closedForBackground = true
        eventLoop?.cancel()
        catalogSettle?.cancel()
        if case .connected(let n) = state { state = .connecting(n) }
        DebugLog.write("背面: 接続を休ませる（セッションを閉じる）")
        // ダイナミックアイランドからは消し、ロック画面にだけしばらく「休ませています」を残す
        activity.end(final: activityContent()?.state, after: 5 * 60)
        cam.requestCloseSession(options: nil) { [weak self] _ in
            Task { @MainActor in
                self?.sessionDidClose(cam)
                self?.endBackgroundTask()
            }
        }
    }

    /// iOS の猶予が尽きた。アプリが背面でも動き続けている（軌跡の記録中）なら、接続は keepSessionInBackground が閉じる
    private func backgroundTimeExpired() {
        let unlimited = UIApplication.shared.backgroundTimeRemaining > 1e6
        DebugLog.write("背面: iOS の猶予が切れた（接続は\(camera?.hasOpenSession == true ? "開いたまま" : "閉じている")、アプリは\(unlimited ? "動き続ける" : "止められる")）")
        if !unlimited, batch.keepSessionUntil == nil, let cam = camera, cam.hasOpenSession {
            closeForBackground(cam)
        }
        endBackgroundTask()
    }

    func appDidBecomeActive() {
        appActive = true
        updatePocketWatch()
        location.appDidBecomeActive()
        if backgroundWatch != nil {
            // 背面にいる間も接続を保っていた。開き直さずにそのまま使う
            backgroundWatch?.cancel()
            backgroundWatch = nil
            backgroundKeepUntil = nil
            endBackgroundTask()
            DebugLog.write("前面へ: 接続は保ったまま")
            return
        }
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
        activitySince = Date()
        state = .connecting(cam.name ?? String(localized: "カメラ"))
        cam.requestOpenSession()
    }

    // MARK: ダイナミックアイランド

    private func refreshActivity() {
        guard let content = activityContent() else {
            activity.end()
            return
        }
        // 背面で休ませたあとの中身は、closeForBackground が最後に 1 回だけ出す
        guard !(closedForBackground && !appActive) else { return }
        activity.show(name: content.name, state: content.state, appActive: appActive)
    }

    private func activityContent() -> (name: String, state: TethrActivityAttributes.ContentState)? {
        let name: String
        let phase: TethrActivityAttributes.ContentState.Phase
        switch state {
        case .connecting(let n):
            name = n
            phase = closedForBackground ? .paused : .preparing
        case .connected(let n):
            name = n
            phase = preparing ? .preparing : (catalogReady ? .connected : .loading)
        default:
            return nil
        }
        var content = TethrActivityAttributes.ContentState(phase: phase, since: activitySince ?? Date())
        content.loaded = deliveredNames.count
        content.expected = expectedObjects
        content.shots = liveShots.count
        content.lastShot = liveShots.first?.name
        content.battery = props[.batteryLevel].map { Int($0.current) }
        content.keepUntil = backgroundKeepUntil
        if let importing = batch.progress, phase == .connected || phase == .loading {
            content.phase = .importing
            content.loaded = importing.done
            content.expected = importing.total
        }
        #if DEBUG
        // 起動引数 -demoActivity=loading などで、表示だけを確かめる
        if demo, let forced = Self.demoArgument("demoActivity"),
           let forcedPhase = TethrActivityAttributes.ContentState.Phase(rawValue: String(forced)) {
            content.phase = forcedPhase
            content.loaded = 234
            content.expected = 455
            content.since = Date().addingTimeInterval(-12)
            if forcedPhase == .connected { content.keepUntil = Date().addingTimeInterval(24) }
        }
        #endif
        return (name, content)
    }

    private func endBackgroundTask() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }

    // MARK: カードの中身

    /// メーカーを読む。白バランス等の独自の値の読み方がメーカーで違うため
    private func readVendor() async {
        guard let ptp else { return }
        let before = PropFormat.vendor
        guard let info = await ptp.readDeviceInfo() else {
            DebugLog.write("DeviceInfo を読めない")
            return
        }
        capabilities = ptp.capabilities
        #if DEBUG
        func hex(_ codes: [UInt16]) -> String { codes.map { String(format: "%04X", $0) }.joined(separator: " ") }
        DebugLog.write("DeviceInfo: \(info.manufacturer) \(info.model)\(capabilities?.isNikon1 == true ? "（Nikon 1）" : "")")
        DebugLog.write("DeviceInfo 命令: " + hex(info.operations))
        DebugLog.write("DeviceInfo イベント: " + hex(info.events))
        DebugLog.write("DeviceInfo プロパティ: " + hex(info.properties))
        #endif
        DebugLog.write(String(format: "メーカー 0x%08X（名乗り 0x%08X / %@）", PropFormat.vendor, info.vendor, info.manufacturer))
        // 独自の値の読み方が切り替わったので、表示を描き直す
        if PropFormat.vendor != before { objectWillChange.send() }
    }

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
        // 番号は 9999 で一巡するので、別の日の同名カットを拾わないよう時刻を確かめる。
        // 以前の記録は位置を測った時刻（立ち止まり中は何時間も前）が入っているので、撮影より前は 1 日まで許す
        if let known = geoLog.shots[shot.name],
           known.time <= time.addingTimeInterval(10 * 60), known.time >= time.addingTimeInterval(-24 * 3600) {
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
            var shot = Shot(name: name, size: Int(file.fileSize), captured: file.creationDate)
            shot.imported = ledger.contains(serial: cameraKey, name: name, size: Int64(file.fileSize), captured: file.creationDate)
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
                        if geoLog.shots[shot.name] == nil {
                            geoLog.recordShot(shot.name, at: here, time: event?.time ?? shot.captured ?? Date())
                        }
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
            guard let self, !Task.isCancelled, self.canSettleCatalog else { return }
            // 接続時に数えたオブジェクト数（フォルダのぶん少し多い）にまだ届いていなければ、しばらく待つ（Mac 版と同じ判定）
            if let expected = self.expectedObjects, self.deliveredNames.count + 10 < expected {
                try? await Task.sleep(for: .seconds(8))
                guard !Task.isCancelled, self.canSettleCatalog else { return }
                DebugLog.write("読み込み: \(expected) 件のうち \(self.deliveredNames.count) 件で到着が止まった")
            }
            self.finishCatalog()
        }
    }

    /// 背面で接続を休ませている間は、ファイルが届かないだけで出そろったわけではない
    /// （以前は休ませた直後に 460 件中 132 件で「読み込み完了」になった）
    private var canSettleCatalog: Bool {
        camera?.hasOpenSession == true && !closedForBackground
    }

    private func finishCatalog() {
        guard !catalogReady else { return }
        // 挿し直しの間にカードが替わっていたら、もう無いカットを外す（取り込み済みは残す）。
        // 完了の判定が早すぎた場合に、まだ届いていないだけのカットを消さないよう、
        // 届いた数が接続時のオブジェクト数にほぼ達しているときに限る（フォルダの分は見逃す）
        if let expected = expectedObjects, deliveredNames.count + 10 >= expected {
            liveShots.removeAll { fileIndex[$0.name] == nil && !$0.imported }
            cardShots.removeAll { fileIndex[$0.name] == nil && !$0.imported }
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
        let inRange = shots.filter { $0.1 >= first.addingTimeInterval(-TrackTiming.interval) && $0.1 <= last.addingTimeInterval(TrackTiming.interval) }
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
        camera = nil
        ptp = nil
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
        guard let ptp, let cameraTime = await ptp.cameraClock() else { return }
        let drift = Date().timeIntervalSince(cameraTime)
        // 撮影時刻での判定に使うので、このカメラで最初に読んだずれを覚えておく
        if clockDrift == nil { clockDrift = drift }
        guard abs(drift) > 2 else { return }   // 誤差の範囲なら触らない
        guard (try? await ptp.setCameraClock(Date())) != nil else { return }
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
        guard let ptp else { return false }
        guard checkEventUsable else {
            let before = lightMeter
            await readLightMeter()
            return before != lightMeter
        }
        let events: [PTPEvent]
        do {
            events = try await ptp.checkEvent()
        } catch PTPError.response(0x2005) {
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
        let others = events.filter { $0.code != PTPEvent.devicePropChanged }
        if !others.isEmpty {
            DebugLog.write("CheckEvent: " + others.map { String(format: "0x%04X(0x%X)", $0.code, $0.param) }.joined(separator: " "))
        }
        #endif
        // DevicePropChanged (0x4006) の引数が、変わったプロパティのコード
        let changed = Set(events.filter { $0.code == PTPEvent.devicePropChanged }.map { UInt16(truncatingIfNeeded: $0.param) })
        guard !changed.isEmpty else { return false }
        // 本体のダイヤルやボタンで設定が変わった＝カメラを触っている。露出計の揺れだけは数えない
        if changed.contains(where: { $0 != UInt16(PTPCamera.lightMeterCode) }) {
            Interaction.touch()
        }

        if changed.contains(UInt16(PTPCamera.lightMeterCode)) {
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

    private func readLightMeter() async {
        guard let ptp, let value = await ptp.lightMeter() else { return }
        lightMeter = value
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

    /// 生の PTP コマンドを送り、応答データを返す（送ってよいかの判定と 45 秒の見張りは PTPCamera）
    @discardableResult
    func send(_ op: PTP.Op, params: [UInt32] = [], outData: Data? = nil) async throws -> Data {
        guard let ptp else { throw PTPError.notConnected }
        return try await ptp.send(op, params: params, outData: outData)
    }

    /// 設定の現在値と選択肢をまとめて読み直す
    func refreshProps() async {
        guard isConnected, let ptp else { return }
        let updated = await ptp.describeAll()
        #if DEBUG
        if props[.nikonExposureTime] == nil, let shutter = updated[.nikonExposureTime] {
            DebugLog.write("Nikon シャッタースピード 0xD100 の選択肢: " + shutter.choices.map {
                String(format: "%d/%d→", Int($0 >> 16), Int($0 & 0xFFFF)) + PropFormat.text(.nikonExposureTime, $0)
            }.joined(separator: " "))
        }
        #endif
        props = updated
    }

    /// 設定を書き換える。通ったかを返す。
    ///
    /// 読み直すのは変えた設定だけにする。全部読み直すと 1 回ごとに往復が 8 回増え、
    /// スクラバーの確定が遅れて見える。連動して変わる他の設定（M で絞りを変えたときの露出計など）は
    /// CheckEvent が拾う。撮影モードだけは書き込み可否がまとめて変わるので全部読み直す。
    @discardableResult
    func setProp(_ prop: PTP.Prop, to value: Int64) async -> Bool {
        guard let desc = props[prop] else { return false }
        #if DEBUG
        if demo { return await demoSetProp(prop, to: value) }
        #endif
        guard let ptp, desc.dataType != .string else { return false }
        do {
            try await ptp.write(desc, value: value)
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
        guard let desc = await ptp?.describe(prop) else { return }
        props[prop] = desc
    }

    /// シャッターを切る。撮影後のファイルはイベント経由で一覧に加わる。
    func capture() async {
        guard isConnected, !busy else { return }
        #if DEBUG
        if demo { return await demoCapture() }
        #endif
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
        guard let ptp else { return false }
        // レリーズの前に必ず AF を通す。
        // 操作を増やさずに、実機のシャッター全押しと同じ挙動にする。
        // 合わなくても撮影は止めない（AF-C や MF では合焦通知自体が来ない）。
        // Nikon 1 はまず libgphoto2 で通っている手順（標準の 0x100E だけ）に合わせ、AF 命令は確かめてから使う
        if capabilities?.isNikon1 != true { _ = await ptp.autofocus() }
        do {
            try await ptp.releaseShutter()
            return true
        } catch {
            lastError = String(localized: "撮影できませんでした: \(describe(error))")
            return false
        }
    }

    private func describe(_ error: Error) -> String {
        if case PTPError.response(let code) = error { return PTP.responseName(code) }
        return error.localizedDescription
    }

    /// 写真アプリへ入った。控えに残し、一覧の印を付ける
    func markImported(_ shot: Shot, preview: URL?) {
        ledger.record(serial: cameraKey, name: shot.name, size: Int64(shot.size), captured: shot.captured)
        if let i = liveShots.firstIndex(where: { $0.name == shot.name }) {
            liveShots[i].imported = true
            liveShots[i].previewURL = preview
        }
        if let i = cardShots.firstIndex(where: { $0.name == shot.name }) {
            cardShots[i].imported = true
            cardShots[i].previewURL = preview
        }
    }

    /// 取り込みの控えに使うカメラの識別。DeviceInfo のシリアル番号（Mac 版と同じ）、読めなければ ImageCaptureCore の UUID
    private var cameraKey: String {
        if let serial = ptp?.info?.serialNumber, !serial.isEmpty { return serial }
        return lastCameraID ?? "?"
    }

    // MARK: サムネイルと取り込み

    /// 画面に出てきたカットのサムネイルだけを取りに行く。
    /// 一括で要求すると 1 枚ごとに PTP の往復が走り、USB 2.0 が飽和して
    /// 他の操作まで待たされる。表示に必要な分だけ、遅延で取る。
    func requestThumbnail(for shot: Shot) {
        #if DEBUG
        if demo, let image = demoPendingThumbnails.removeValue(forKey: shot.name) {
            Task {
                try? await Task.sleep(for: .milliseconds(Int.random(in: 300...1200)))
                if let i = cardShots.firstIndex(where: { $0.name == shot.name }) { cardShots[i].thumbnail = image }
            }
            return
        }
        #endif
        if pocketed {
            deferredThumbnails.insert(shot.name)
            return
        }
        guard shot.thumbnail == nil, !thumbnailRequested.contains(shot.name),
              let file = fileIndex[shot.name] else { return }
        thumbnailRequested.insert(shot.name)
        // 一覧用は小さくてよい。大きく要求すると転送量が増えて一覧の描画が遅れる。
        // 向きはプレビューを読むまで分からない。ImageCaptureCore が知っていればそれを使う
        let reported = Int(file.orientation.rawValue)
        let hint = reported == 1 ? nil : reported
        file.requestThumbnailData(options: [.imageSourceThumbnailMaxPixelSize: 320]) { [weak self] data, _ in
            guard let data, let image = UIImage(data: data) else { return }
            Task { @MainActor in
                guard let self else { return }
                if let i = self.liveShots.firstIndex(where: { $0.name == shot.name }) {
                    self.liveShots[i].thumbnail = image.applyingCameraOrientation(self.liveShots[i].orientation ?? hint)
                }
                if let i = self.cardShots.firstIndex(where: { $0.name == shot.name }) {
                    self.cardShots[i].thumbnail = image.applyingCameraOrientation(self.cardShots[i].orientation ?? hint)
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

            var orientation: Int?
            // 先頭部分だけ読んで、埋め込み JPEG の位置と撮影時の向きを割り出す
            if let header = await self.read(file, offset: 0, length: 128 * 1024) {
                orientation = NEF.orientation(in: header)
                if let loc = NEF.largestPreview(in: header),
                   loc.length > 0, loc.length < 40 * 1024 * 1024,
                   let jpeg = await self.read(file, offset: off_t(loc.offset), length: off_t(loc.length)) {
                    image = UIImage(data: jpeg)
                }
            }
            // 構造を辿れないファイル形式のときは、従来のサムネイル要求に戻す
            if image == nil {
                image = await self.thumbnailData(file, maxPixel: 2400).flatMap(UIImage.init(data:))
            }
            guard let image else { return }
            #if DEBUG
            if let orientation, orientation != 1 {
                DebugLog.write("向き: \(shot.name) Orientation=\(orientation) ICC=\(file.orientation.rawValue) 埋め込み \(Int(image.size.width))×\(Int(image.size.height))")
            }
            #endif
            self.applyPreview(image.applyingCameraOrientation(orientation), orientation: orientation, to: shot.name)
        }
    }

    /// プレビューと向きを入れる。先に届いていたサムネイルも同じ向きに回す
    private func applyPreview(_ image: UIImage, orientation: Int?, to name: String) {
        if let i = liveShots.firstIndex(where: { $0.name == name }) {
            liveShots[i].preview = image
            liveShots[i].orientation = orientation
            liveShots[i].thumbnail = liveShots[i].thumbnail?.applyingCameraOrientation(orientation)
        }
        if let i = cardShots.firstIndex(where: { $0.name == name }) {
            cardShots[i].preview = image
            cardShots[i].orientation = orientation
            cardShots[i].thumbnail = cardShots[i].thumbnail?.applyingCameraOrientation(orientation)
        }
    }

    /// 読み出しの手順は TethrKit の CardFile（Mac 版と共通、60 秒で打ち切る）。
    /// 読んでいる間は露出計の問い合わせを休む
    private func read(_ file: ICCameraFile, offset: off_t, length: off_t) async -> Data? {
        transferCount += 1
        defer { transferCount -= 1 }
        let data = await CardFile.read(file, offset: offset, length: length)
        if data == nil { DebugLog.write("読み出し失敗: \(file.name ?? "?") @\(offset) 長さ \(length)") }
        return data
    }

    private func thumbnailData(_ file: ICCameraFile, maxPixel: Int) async -> Data? {
        await CardFile.thumbnailData(file, maxPixel: maxPixel)
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
                // 複製せずに写真アプリへ移す。11MB のコピーが減り、端末に NEF が残らない
                options.shouldMoveFile = true
                request.addResource(with: .photo, fileURL: url, options: options)
                // RAW 本体には手を触れず、写真アプリの資産情報として位置を持たせる
                if let coordinate { request.location = coordinate }
                if let captured = shot.captured { request.creationDate = captured }
            }
            return true
        } catch {
            lastError = String(localized: "写真アプリに保存できませんでした: \(error.localizedDescription)")
            return false
        }
    }

    /// カメラから読み出し、写真アプリへ移す。写真アプリに入ったかを返す。
    ///
    /// 読み出した NEF は写真アプリへ移すので、端末には残らない（以前は取り込むたびに 11MB ずつ溜まっていた）。
    /// 大きな写真の表示に使う JPEG だけを、先に取り出してキャッシュに置く
    @discardableResult
    func importShot(_ shot: Shot, reportErrors: Bool = true) async -> Bool {
        #if DEBUG
        if demo { return await demoImport(shot) }
        #endif
        var shot = shot
        if shot.location == nil, geotagging, !liveShots.contains(where: { $0.name == shot.name }) {
            // 一覧に並べた後に軌跡が増えていることがある（Mac へ送る前の記録など）。取り込む時点でもう一度探す
            shot.location = cardLocation(for: shot)
            if let i = cardShots.firstIndex(where: { $0.name == shot.name }) { cardShots[i].location = shot.location }
        }
        DebugLog.write("取り込み: \(shot.name) 位置 \(shot.location.map { String(format: "%.5f,%.5f ±%.0fm", $0.coordinate.latitude, $0.coordinate.longitude, $0.horizontalAccuracy) } ?? "なし")")
        guard importProgress[shot.name] == nil else { return false }
        importProgress[shot.name] = 0
        guard let url = await download(shot, reportErrors: reportErrors) else {
            importProgress[shot.name] = nil
            return false
        }
        // 読み出しで 9 割、写真アプリへの保存で残りを満たす
        importProgress[shot.name] = 0.95
        let preview = await ImportFiles.cachePreview(from: url, name: shot.name)
        let saved = await saveToPhotos(url, shot: shot)
        // 写真アプリへ移せなかったときも、端末に NEF を溜めない（取り込み直せばよい）
        try? FileManager.default.removeItem(at: url)
        if saved {
            markImported(shot, preview: preview)
        } else if let preview {
            try? FileManager.default.removeItem(at: preview)
        }
        await finishImportProgress(shot.name)
        return saved
    }

    /// 満ちきったところを一瞬見せてから、保存済みの表示に切り替える
    private func finishImportProgress(_ name: String) async {
        importProgress[name] = 1
        try? await Task.sleep(for: .milliseconds(220))
        importProgress[name] = nil
    }

    /// 進み具合を画面に出す。ObservableObject 全体が描き直されるので、細かい変化は間引く
    private func reportDownloadProgress(_ name: String, _ fraction: Double) {
        guard let current = importProgress[name] else { return }
        let value = min(max(fraction, 0), 1) * 0.9
        guard value - current >= 0.03 else { return }
        importProgress[name] = value
    }

    private func download(_ shot: Shot, reportErrors: Bool = true) async -> URL? {
        guard let file = fileIndex[shot.name] else { return nil }
        transferCount += 1
        defer { transferCount -= 1 }
        let dir = ImportFiles.downloads
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let name = shot.name
        let watch = ProgressWatch()
        let url: URL? = await withCheckedContinuation { cont in
            let progress = file.requestDownload(options: [
                .downloadsDirectoryURL: dir,
                .overwrite: true,
            ]) { filename, error in
                watch.stop()
                if let error {
                    DebugLog.write("取り込みの読み出しに失敗: \(name) \(error.localizedDescription)")
                    // まとめて取り込むときは、背面で止められただけのことが多い。戻ってからやり直すので知らせない
                    if reportErrors {
                        Task { @MainActor in self.lastError = String(localized: "取り込みに失敗しました: \(error.localizedDescription)") }
                    }
                    cont.resume(returning: nil)
                    return
                }
                cont.resume(returning: filename.map { dir.appendingPathComponent($0) })
            }
            watch.start(progress) { [weak self] fraction in
                Task { @MainActor in self?.reportDownloadProgress(name, fraction) }
            }
        }
        return url
    }
}

#if DEBUG
// MARK: - デモ

/// シミュレータにはカメラをつなげないので、画面を詰めるときはつながったふりをする。
/// 起動引数 -demo で入る。製品版には含めない
extension CameraSession {
    static var demoRequested: Bool { ProcessInfo.processInfo.arguments.contains("-demo") }

    private static func demoArgument(_ name: String) -> Substring? {
        ProcessInfo.processInfo.arguments.first { $0.hasPrefix("-\(name)=") }?.dropFirst(name.count + 2)
    }

    /// 起動引数 -demoMode=M のように撮影モードを選べる
    private static var demoStartMode: Int64 { DemoCamera.mode(named: demoArgument("demoMode")) }

    func loadDemo() {
        demo = true
        PropFormat.vendor = PropFormat.vendorNikon
        state = .connected("D300")
        catalogReady = true
        catalogProgress = 100
        applyDemoValues(DemoCamera.startValues(mode: Self.demoStartMode))
        let now = Date()
        let here = CLLocation(latitude: 35.6812, longitude: 139.7671)
        liveShots = (0..<3).map { i in
            let image = DemoImage.shot(seed: i, portrait: i == 1)
            return Shot(name: String(format: "_DSC%04d.NEF", 5182 - i), size: 11_400_000 - i * 180_000,
                        captured: now.addingTimeInterval(Double(-i * 45)),
                        thumbnail: image, preview: image, location: i == 2 ? nil : here)
        }
        cardShots = (0..<24).map { i in
            let image = DemoImage.shot(seed: i + 10, portrait: i % 5 == 3)
            return Shot(name: String(format: "_DSC%04d.NEF", 5179 - i), size: 10_900_000,
                        captured: now.addingTimeInterval(Double(-3600 - i * 300)),
                        thumbnail: image, preview: image)
        }
        // カード側のサムネイルは、実機と同じく一覧に出てから届くようにする
        for i in cardShots.indices {
            demoPendingThumbnails[cardShots[i].name] = cardShots[i].thumbnail
            cardShots[i].thumbnail = nil
        }
        cardShots[1].imported = true
        // -demoCard でカード側、-demoShot=1 で何枚目を選ぶか、-demoLive でライブビュー
        browsingCard = ProcessInfo.processInfo.arguments.contains("-demoCard")
        let index = Self.demoArgument("demoShot").flatMap { Int($0) } ?? 0
        selection = shots.indices.contains(index) ? shots[index].id : shots.first?.id
        // -demoAct で、起動の 2.5 秒後にシャッターと取り込みを押したことにする（押している最中の見た目を撮るため）
        if ProcessInfo.processInfo.arguments.contains("-demoAct") {
            Task {
                try? await Task.sleep(for: .milliseconds(2500))
                if let shot = shots.first(where: { $0.id == selection }) { await importShot(shot) }
                await capture()
            }
        }
        if ProcessInfo.processInfo.arguments.contains("-demoReview") {
            reviewOnReturn = selection
        }
        if ProcessInfo.processInfo.arguments.contains("-demoLive") {
            Task { await live.start() }
        }
    }

    private func demoSetProp(_ prop: PTP.Prop, to value: Int64) async -> Bool {
        // PTP の往復ぶん待たせて、返事待ちの表示も確かめられるようにする
        try? await Task.sleep(for: .milliseconds(150))
        var values = props.mapValues(\.current)
        values[prop] = value
        applyDemoValues(values)
        return true
    }

    private func demoCapture() async {
        busy = true
        try? await Task.sleep(for: .milliseconds(1400))
        busy = false
        Haptics.shotArrived()
        let number = 5183 + liveShots.count
        let image = DemoImage.shot(seed: number, portrait: number % 4 == 0)
        let shot = Shot(name: String(format: "_DSC%04d.NEF", number), size: 11_200_000, captured: Date(),
                        thumbnail: image, preview: image, location: CLLocation(latitude: 35.6812, longitude: 139.7671))
        liveShots.insert(shot, at: 0)
        browsingCard = false
        selection = shot.id
    }

    private func demoImport(_ shot: Shot) async -> Bool {
        guard importProgress[shot.name] == nil else { return false }
        importProgress[shot.name] = 0
        // 最初の数字が届くまでの間（光の帯）も見えるようにする
        try? await Task.sleep(for: .milliseconds(500))
        for step in 1...20 {
            try? await Task.sleep(for: .milliseconds(60))
            reportDownloadProgress(shot.name, Double(step) / 20)
        }
        importProgress[shot.name] = 0.95
        if let i = liveShots.firstIndex(where: { $0.name == shot.name }) { liveShots[i].imported = true }
        if let i = cardShots.firstIndex(where: { $0.name == shot.name }) { cardShots[i].imported = true }
        try? await Task.sleep(for: .milliseconds(150))
        await finishImportProgress(shot.name)
        return true
    }

    /// 撮影モードに応じて、カメラ任せの値と露出計を D300 らしく動かす（規則は Mac と共通の DemoCamera）
    private func applyDemoValues(_ input: [PTP.Prop: Int64]) {
        let demo = DemoCamera.apply(input)
        lightMeter = demo.lightMeter
        props = demo.props
    }
}

/// デモ用の写真。空と山と太陽だけの、色の違う風景
enum DemoImage {
    /// カメラと同じく、縦位置のカットは横長の画素に向き 6 を付けて返す
    static func shot(seed: Int, portrait: Bool) -> UIImage {
        let upright = make(seed: seed, portrait: portrait)
        guard portrait, let cg = upright.cgImage else { return upright }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let sideways = UIGraphicsImageRenderer(size: CGSize(width: cg.height, height: cg.width), format: format).image { ctx in
            // 表示のとき時計回りに 90 度回して正立するよう、反時計回りに寝かせる
            ctx.cgContext.translateBy(x: 0, y: CGFloat(cg.width))
            ctx.cgContext.rotate(by: -.pi / 2)
            UIImage(cgImage: cg).draw(at: .zero)
        }
        return sideways.applyingCameraOrientation(6)
    }

    /// 絵そのものは Mac と共通の DemoLandscape
    static func make(seed: Int, portrait: Bool, sunShift: Double = 0) -> UIImage {
        DemoLandscape.make(seed: seed, portrait: portrait, sunShift: sunShift).map { UIImage(cgImage: $0) } ?? UIImage()
    }
}
#endif

/// ダウンロードの Progress を見張る。完了の通知と進み具合の通知は別のキューから来るので、止めるのを 1 か所にまとめる
private final class ProgressWatch: @unchecked Sendable {
    private let lock = NSLock()
    private var observation: NSKeyValueObservation?
    private var stopped = false

    func start(_ progress: Progress?, onChange: @escaping (Double) -> Void) {
        guard let progress else { return }
        let observation = progress.observe(\.fractionCompleted, options: [.new]) { p, _ in
            onChange(p.fractionCompleted)
        }
        lock.lock()
        defer { lock.unlock() }
        if stopped { observation.invalidate() } else { self.observation = observation }
    }

    func stop() {
        lock.lock()
        defer { lock.unlock() }
        stopped = true
        observation?.invalidate()
        observation = nil
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
            let ptp = PTPCamera(device: cam) { DebugLog.write($0) }
            self.ptp = ptp
            self.live.attach(ptp, identifier: id ?? "?")
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
                if let ptp = self.ptp { await NikonLiveView.restoreIfInterrupted(ptp) }
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
            #if DEBUG
            if !self.appActive { DebugLog.write("背面で一覧に届いた: \(files.count) 件（\(files.first?.name ?? "?")）") }
            #endif
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

    /// カメラから届く PTP イベント（読み方は TethrKit の PTPEvent）
    nonisolated func cameraDevice(_ camera: ICCameraDevice, didReceivePTPEvent eventData: Data) {
        guard let event = PTPEvent.container(eventData) else { return }
        let param = event.param
        Task { @MainActor in
            guard camera === self.camera else { return }
            #if DEBUG
            if !self.appActive { DebugLog.write(String(format: "背面で PTP イベント 0x%04X (0x%X)", event.code, param)) }
            #endif
            switch event.code {
            case PTPEvent.objectAdded:
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
                DebugLog.write(String(format: "撮影通知 handle=0x%08X", param))
            case PTPEvent.devicePropChanged:
                // DevicePropChanged。Nikon 1 のように CheckEvent を使えない機種は、本体側の変更をここで拾う
                guard !self.checkEventUsable, !self.pocketed else { return }
                if let prop = PTP.Prop(rawValue: UInt16(truncatingIfNeeded: param)) {
                    await self.refreshPropForEvent(prop)
                }
            case PTPEvent.captureComplete:
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
