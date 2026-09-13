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
        props[.exposureProgram]?.current == 1   // PTP の ExposureProgramMode: 1 = Manual
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
    /// 位置が後から届く撮影通知と、それに対応づいたカット名
    private var fixTargets: [Int: String] = [:]
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
    private var appActive = true
    private var shotsWhilePocketed = 0
    /// ポケットの中で取らずにおいたサムネイル
    private var deferredThumbnails: Set<String> = []
    private var prefetchTask: Task<Void, Never>?

    /// 一覧に出す設定の並び
    static let displayed: [PTP.Prop] = [.exposureProgram, .exposureTime, .fNumber, .iso, .exposureBias]
    /// スクラバーで操作する設定
    static let adjustable: [PTP.Prop] = [.exposureTime, .fNumber, .iso]

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
    }

    private func updatePocketWatch() {
        pocket.active = pocketModeEnabled && isConnected && appActive
    }

    private func pocketChanged(_ value: Bool) {
        pocketed = value
        if value {
            shotsWhilePocketed = 0
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
            fixTargets[id] = nil
            return
        }
        if let i = shotEvents.firstIndex(where: { $0.id == id }) {
            shotEvents[i].location = fix
        } else if let name = fixTargets.removeValue(forKey: id) {
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

    /// セッションを閉じる。カメラの参照は保つので、同じカメラなら開き直しは一瞬で済む。
    func disconnect() {
        guard let cam = camera else { return }
        eventLoop?.cancel()
        cam.requestCloseSession()
        state = .idle
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
        eventLoop?.cancel()
        if case .connected(let n) = state { state = .connecting(n) }
        DebugLog.write("背面へ: セッションを閉じる")
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "close-camera-session") { [weak self] in
            Task { @MainActor in self?.endBackgroundTask() }
        }
        cam.requestCloseSession(options: nil) { [weak self] _ in
            Task { @MainActor in self?.endBackgroundTask() }
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

    private func reopen(_ cam: ICCameraDevice) {
        DebugLog.write("前面へ: セッションを開き直す")
        state = .connecting(cam.name ?? "カメラ")
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
        guard let data = try? await send(.getDeviceInfo) else { return }
        var r = PTPReader(data)
        guard r.read(UInt16.self) != nil, let vendor = r.read(UInt32.self) else { return }
        if PropFormat.vendor != vendor {
            PropFormat.vendor = vendor
            DebugLog.write(String(format: "メーカー 0x%08X", vendor))
            objectWillChange.send()
        }
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

    /// 撮影通知のうち、このカットのものを取り出す。時計のずれと転送の遅れぶんは許す
    private func takeShotEvent(near taken: Date) -> ShotEvent? {
        let tolerance = abs(clockDrift ?? 0) + 5
        guard let i = shotEvents.firstIndex(where: { abs($0.time.timeIntervalSince(taken)) <= tolerance }) else { return nil }
        let event = shotEvents[i]
        // それより古い通知は対になるカットが来なかったもの。捨てる
        shotEvents.removeFirst(i + 1)
        return event
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
                    let event = shot.captured.flatMap(takeShotEvent(near:))
                    // 精密な位置がまだ取れていなければ、取れたときにこのカットへ入れる
                    if let event, event.location == nil { fixTargets[event.id] = shot.name }
                    let here = event?.location
                        ?? geoLog.shots[shot.name]?.location
                        ?? shot.captured.flatMap { geoLog.location(near: $0) }
                        ?? location.current
                    if let here {
                        shot.location = here
                        if geoLog.shots[shot.name] == nil { geoLog.recordShot(shot.name, at: here) }
                    }
                    DebugLog.write("テザー側: \(shot.name) 撮影 \(shot.captured.map { "\($0)" } ?? "?") 位置の出どころ=\(event?.location != nil ? "撮影通知" : here == nil ? "なし" : "軌跡か現在地")")
                } else {
                    DebugLog.write("テザー側: \(shot.name)")
                }
                added.append(shot)
            }
            liveShots.insert(contentsOf: added.reversed(), at: 0)
            selection = liveShots.first?.id
            for shot in added { requestThumbnail(for: shot) }
            if pocketed {
                shotsWhilePocketed += added.count
                schedulePrefetch()
            }
        }
        if !card.isEmpty {
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
    }

    /// 抜かれたカメラの後始末。挿し直すとオブジェクトが作り直されるので、それに紐づく状態は捨てる。
    /// カットの一覧は残す。うっかりケーブルが抜けても、同じカメラなら続きから使えるように。
    private func forgetDevice() {
        UserDefaults.standard.set(Date(), forKey: "lastSessionEnded")
        camera = nil
        fileIndex = [:]
        connectedAt = nil
        clockDrift = nil
        classifyReady = false
        pendingFiles = []
        expectedObjects = nil
        deliveredNames = []
        shotEvents = []
        fixTargets = [:]
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
        let changed = Self.changedProperties(in: data)
        guard !changed.isEmpty else { return false }

        if changed.contains(UInt16(Self.lightMeterProp)) {
            await readLightMeter()
        }
        // 露出まわりが動いたら、表示している設定を読み直す
        let watched = Set(PTP.Prop.allCases.map(\.rawValue))
        if !changed.isDisjoint(with: watched) {
            await refreshProps()
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
        if props[.exposureTime] == nil, let shutter = updated[.exposureTime] {
            DebugLog.write("シャッタースピードの選択肢（生の値→表示）: " + shutter.choices.map { "\($0)→\(PropFormat.text(.exposureTime, $0))" }.joined(separator: " "))
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
        for _ in 0..<30 {
            if (try? await send(.nikonDeviceReady)) != nil { return }
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    /// シャッターを切る。撮影後のファイルはイベント経由で一覧に加わる。
    func capture() async {
        guard isConnected, !busy else { return }
        busy = true
        defer { busy = false }
        // レリーズの前に必ず AF を通す。
        // 操作を増やさずに、実機のシャッター全押しと同じ挙動にする。
        await autofocus()
        do {
            try await send(.initiateCapture, params: [0, 0])
            DebugLog.write("リモートシャッター 0x100E: OK")
        } catch {
            DebugLog.write("リモートシャッター 0x100E 失敗: \(describe(error))")
            // 標準命令が通らない機種向けに Nikon 独自命令も試す
            if (try? await send(.nikonCapture, params: [0xFFFFFFFF])) == nil {
                lastError = String(localized: "撮影できませんでした: \(describe(error))")
            }
        }
        await refreshProps()
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
            self.state = .connecting(cam.name ?? "カメラ")
            DebugLog.write("カメラを検出: \(cam.name ?? "?") \(id ?? "?")")
            cam.requestOpenSession()
        }
    }

    nonisolated func deviceBrowser(_ browser: ICDeviceBrowser, didRemove device: ICDevice, moreGoing: Bool) {
        Task { @MainActor in
            guard device === self.camera else { return }
            self.forgetDevice()
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
            self.state = .connected(device.name ?? "カメラ")
            DebugLog.write("セッションを開いた")
            if self.connectedAt == nil {
                // このカメラで初めて開いた。ここから準備完了まで命令が通らない
                self.connectedAt = opened
                self.preparing = true
            }
            if !self.catalogReady { self.startProgressWatch() }
            // 時計は準備完了まで読めない。読み終えたら、溜めていたファイルを判定して流す
            await self.syncClock()
            self.preparing = false
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
            await self.readVendor()
            self.scheduleCatalogSettle()
            self.checkEventUsable = true
            self.startEventPolling()
            await self.refreshProps()
        }
    }

    nonisolated func device(_ device: ICDevice, didCloseSessionWithError error: (any Error)?) {
        Task { @MainActor in
            UserDefaults.standard.set(Date(), forKey: "lastSessionEnded")
            guard device === self.camera else { return }
            DebugLog.write("セッションを閉じた")
            if self.reopenAfterClose, let cam = self.camera {
                self.reopenAfterClose = false
                self.reopen(cam)
            } else if !self.closedForBackground {
                self.state = .idle
            }
        }
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
                if self.shotEvents.count > 200 { self.shotEvents.removeFirst(self.shotEvents.count - 200) }
                if self.geotagging {
                    // 立ち止まって衛星を止めていれば保持している位置がすぐ返り、無ければ衛星を起こして取る
                    self.location.fixForShot { [weak self] fix in
                        Task { @MainActor in self?.applyShotFix(id: id, fix) }
                    }
                }
                DebugLog.write("撮影通知 handle=\(param.map { String(format: "0x%08X", $0) } ?? "?")")
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
