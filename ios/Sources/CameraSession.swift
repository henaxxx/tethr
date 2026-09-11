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

    @Published private(set) var state: LinkState = .idle
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

    func disconnect() {
        camera?.requestCloseSession()
        camera = nil
        liveShots = []
        cardShots = []
        catalogReady = false
        thumbnailRequested = []
        previewRequested = []
        progressTimer?.invalidate()
        eventLoop?.cancel()
        geoLog.save()
        lightMeter = nil
        clockCorrection = nil
        transferCount = 0
        fileIndex = [:]
        props = [:]
        state = .idle
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
        while !Task.isCancelled {
            let interval: Duration =
                quiet > 12 ? .milliseconds(2000) :
                quiet > 4  ? .milliseconds(900)  :
                             .milliseconds(350)
            try? await Task.sleep(for: interval)

            guard isConnected else { return }
            // 画面が見えていない、撮影中、転送中は叩かない
            guard !suspended, !busy, transferCount == 0 else { continue }

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
        guard let data = try? await send(.nikonCheckEvent) else {
            // 対応していない機種だった。以後は露出計だけ直接読む。
            checkEventUsable = false
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
    private func startProgressWatch() {
        progressTimer?.invalidate()
        progressTimer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { [weak self] timer in
            Task { @MainActor in
                guard let self, let cam = self.camera else { timer.invalidate(); return }
                self.catalogProgress = Int(cam.contentCatalogPercentCompleted)
                if self.catalogReady { timer.invalidate() }
            }
        }
    }

    // MARK: PTP

    /// 生の PTP コマンドを送り、応答データを返す。
    @discardableResult
    func send(_ op: PTP.Op, params: [UInt32] = [], outData: Data? = nil) async throws -> Data {
        guard let cam = camera else { throw CameraError.notConnected }
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
        props = updated
    }

    /// 設定を書き換える。データ型に応じた幅で値を渡す必要がある。
    func setProp(_ prop: PTP.Prop, to value: Int64) async {
        guard let desc = props[prop] else { return }
        var payload = Data()
        switch desc.dataType {
        case .int8, .uint8:   payload.appendLE(UInt8(truncatingIfNeeded: value))
        case .int16, .uint16: payload.appendLE(UInt16(truncatingIfNeeded: value))
        case .int32, .uint32: payload.appendLE(UInt32(truncatingIfNeeded: value))
        case .int64, .uint64: payload.appendLE(UInt64(truncatingIfNeeded: value))
        case .string:         return
        }
        do {
            try await send(.setDevicePropValue, params: [UInt32(prop.rawValue)], outData: payload)
            await refreshProps()
        } catch {
            lastError = String(localized: "\(prop.label) を変更できませんでした: \(describe(error))")
        }
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
        } catch {
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
        guard !thumbnailRequested.contains(shot.name),
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
        guard let file = fileIndex[shot.name] else { return }
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
        return await withCheckedContinuation { cont in
            file.requestReadData(atOffset: offset, length: length) { data, _ in
                cont.resume(returning: data)
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
            self.camera = cam
            cam.delegate = self
            self.state = .connecting(cam.name ?? "カメラ")
            cam.requestOpenSession()
        }
    }

    nonisolated func deviceBrowser(_ browser: ICDeviceBrowser, didRemove device: ICDevice, moreGoing: Bool) {
        Task { @MainActor in
            guard device === self.camera else { return }
            self.camera = nil
            self.state = .failed("カメラが取り外されました")
        }
    }
}

// MARK: - セッションとファイル

extension CameraSession: ICCameraDeviceDelegate {

    nonisolated func device(_ device: ICDevice, didOpenSessionWithError error: (any Error)?) {
        Task { @MainActor in
            if let error {
                self.state = .failed(error.localizedDescription)
            } else {
                self.state = .connected(device.name ?? "カメラ")
                self.startProgressWatch()
                await self.syncClock()
                self.startEventPolling()
                await self.refreshProps()
            }
        }
    }

    nonisolated func device(_ device: ICDevice, didCloseSessionWithError error: (any Error)?) {
        Task { @MainActor in self.state = .idle }
    }

    nonisolated func didRemove(_ device: ICDevice) {
        Task { @MainActor in
            self.camera = nil
            self.state = .idle
        }
    }

    nonisolated func deviceDidBecomeReady(_ device: ICDevice) {}

    nonisolated func cameraDevice(_ camera: ICCameraDevice, didAdd items: [ICCameraItem]) {
        let files = items.compactMap { $0 as? ICCameraFile }
        Task { @MainActor in
            var added: [Shot] = []
            for file in files {
                guard let name = file.name else { continue }
                if self.fileIndex[name] != nil { continue }
                self.fileIndex[name] = file
                var shot = Shot(name: name, size: Int(file.fileSize), captured: file.creationDate)
                // 撮影から 1〜2 秒で届くので、いまの位置が撮影地点とみなせる。
                // 取り込みが後回しになっても、この時点の位置が残る。
                if self.catalogReady, self.geotagging, let here = self.location.current {
                    shot.location = here
                    // ファイル名で確定した位置として控える。
                    // 時刻の突き合わせが不要になるぶん、誤差が入らない。
                    self.geoLog.recordShot(name, at: here)
                }
                added.append(shot)
            }
            guard !added.isEmpty else { return }
            if self.catalogReady {
                // 接続後に撮られたカット。これがテザー撮影の本体。
                self.liveShots.insert(contentsOf: added.sorted { $0.name > $1.name }, at: 0)
                self.selection = self.liveShots.first?.id
                for shot in added { self.requestThumbnail(for: shot) }
            } else {
                // 起動時のカタログ読み込み。ここでサムネイルは取らない。
                self.cardShots.append(contentsOf: added)
            }
        }
    }

    nonisolated func cameraDevice(_ camera: ICCameraDevice, didRemove items: [ICCameraItem]) {}
    nonisolated func cameraDevice(_ camera: ICCameraDevice, didRenameItems items: [ICCameraItem]) {}
    nonisolated func cameraDeviceDidChangeCapability(_ camera: ICCameraDevice) {}
    nonisolated func cameraDevice(_ camera: ICCameraDevice, didReceiveThumbnail thumbnail: CGImage?, for item: ICCameraItem, error: (any Error)?) {}
    nonisolated func cameraDevice(_ camera: ICCameraDevice, didReceiveMetadata metadata: [AnyHashable: Any]?, for item: ICCameraItem, error: (any Error)?) {}
    nonisolated func cameraDeviceDidEnableAccessRestriction(_ device: ICDevice) {}
    nonisolated func cameraDeviceDidRemoveAccessRestriction(_ device: ICDevice) {}

    /// 撮影完了などのイベント。撮影直後は設定が変わっていることがあるので読み直す。
    nonisolated func cameraDevice(_ camera: ICCameraDevice, didReceivePTPEvent eventData: Data) {
        guard eventData.count >= 8 else { return }
        let code = UInt16(eventData[eventData.startIndex + 6]) | (UInt16(eventData[eventData.startIndex + 7]) << 8)
        guard code == 0x400D else { return }   // CaptureComplete
        Task { @MainActor in await self.refreshProps() }
    }

    /// カード全体の読み込みが終わった合図。
    /// これ以降に届くファイルが「接続中に撮ったカット」になる。
    nonisolated func deviceDidBecomeReady(withCompleteContentCatalog device: ICCameraDevice) {
        Task { @MainActor in
            self.cardShots.sort { $0.name > $1.name }
            self.catalogReady = true
            self.catalogProgress = 100
            self.progressTimer?.invalidate()
        }
    }
}
