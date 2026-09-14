import Foundation
import ImageCaptureCore
import TethrKit

/// カメラを見つけてセッションを開き、接続後に撮ったカットを保存先へ落とす。
///
/// 以前は libgphoto2 で直接 USB を掴んでいて、そのために macOS のカメラ管理プロセス（ptpcamerad）を
/// 接続のたびに kill していた。いまは iOS 版と同じく ImageCaptureCore を通すので、
/// ptpcamerad とは取り合わず、その上で生の PTP 命令を送る（命令そのものは TethrKit）。
///
/// macOS で実機（D300）を測った結果
/// - カメラがつながったままなら、アプリを開き直しても一覧は 0.03 秒で揃い、命令もすぐ通る
///   （ptpcamerad が一覧を覚えている）
/// - 電源を入れた直後は、セッションは開くが約 43 秒は命令が返らず、そのあとファイルが 1 秒 10 件ずつ届く
///   （完了の合図はファイルより先に来る）。448 件で合わせて 1 分半ほど
@MainActor
final class CameraLink: NSObject {

    enum Phase: Equatable {
        /// セッションを開いていない（カメラが見えていても）
        case closed
        /// 開きたいが、USB にカメラがいない
        case searching
        /// USB には挿さっているが、ImageCaptureCore がまだ知らせてこない（電源を入れた直後、macOS がカードを下調べしている）
        case detected(String, since: Date)
        case opening(String)
        /// セッションは開いたが、カードの下調べで命令が通らない
        case preparing(String)
        case ready(String)
    }

    private(set) var phase: Phase = .closed {
        didSet { if phase != oldValue { onPhase?(phase) } }
    }
    private(set) var camera: PTPCamera?

    var onPhase: ((Phase) -> Void)?
    /// セッションを開いて DeviceInfo を読み終えた。設定の読み込みや問い合わせはここから始める
    var onReady: ((PTPCamera) -> Void)?
    /// カメラが外れた、またはセッションが閉じた
    var onLost: ((String?) -> Void)?
    var onPTPEvent: ((PTPEvent) -> Void)?
    /// テザーで撮ったカットを保存した
    var onFileSaved: ((URL, ICCameraFile) -> Void)?
    var onDownloadFailed: ((String, String) -> Void)?
    /// カード内のファイルが増えた、または一覧が出そろった（まとめて知らせる）
    var onCardChanged: (() -> Void)?

    /// カード内のファイル（フォルダ名/ファイル名で引く）。接続前からあったものも含む。
    /// 番号が 9999 で一巡すると、別のフォルダに同じ名前のファイルが並ぶので、名前だけでは引かない
    private(set) var cardFiles: [String: ICCameraFile] = [:]
    /// 一覧が出そろった。完了の合図は先に来るので、ファイルの到着が途切れるまで待って決める
    private(set) var cardSettled = false
    /// 接続時点でカードにあったオブジェクトの数（フォルダを含む）。出そろったかの判定と、読み込み中の分母に使う
    private(set) var cardExpected: Int?
    private var frameworkCatalogDone = false
    private var settleTask: Task<Void, Never>?
    private var cardNotifyTask: Task<Void, Never>?

    /// 撮影ファイルの保存先
    var destination: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Pictures/Tethr")
    /// 転送に成功したらカードから消すか
    var deleteAfterDownload = false
    /// 保存中の数。問い合わせを控えるのに使う
    private(set) var downloading = 0

    private let browser = ICDeviceBrowser()
    private let usb = USBCameraWatcher()
    private var device: ICCameraDevice?
    /// 利用者がつなぎたいと言っている。カメラが後から現れたら開く
    private var wantsSession = false
    private var openedAt: Date?
    /// 接続時点のカメラ時計のずれ（Mac − カメラ、秒）。撮影時刻で「接続後のカットか」を決めるのに使う
    private(set) var clockDrift: TimeInterval?
    /// 時計を読むまでは判定できないので、届いたファイルを溜めておく
    private var classifyReady = false
    private var pendingFiles: [ICCameraFile] = []
    /// このセッションで見たファイル名。開き直しで同じものが届き直しても数え直さない
    private var seenNames: Set<String> = []
    /// 保存したファイル（名前と大きさ）。開き直しで同じカットを二度落とさない
    private var savedFiles: Set<String> = []
    private var queue: [ICCameraFile] = []
    private var draining = false

    override init() {
        super.init()
        browser.delegate = self
        browser.browsedDeviceTypeMask = ICDeviceTypeMask(
            rawValue: ICDeviceTypeMask.camera.rawValue | ICDeviceLocationTypeMask.local.rawValue
        )!
        browser.start()
        usb.onChange = { [weak self] in self?.usbChanged() }
        usb.start()
    }

    /// カメラが USB に現れた時刻（分かれば）。つながるまでの待ち時間を数える起点にする
    var attachedSince: Date? { usb.camera?.since }

    var isReady: Bool {
        if case .ready = phase { return true }
        return false
    }

    // MARK: 接続と切断

    func open() {
        wantsSession = true
        guard let device else {
            phase = waitingPhase
            Log.write(usb.camera.map { "接続: USB に \($0.name) がいる。macOS の準備を待つ" } ?? "接続: カメラを探しています")
            return
        }
        guard !device.hasOpenSession else { return }
        begin(device)
    }

    func close() {
        wantsSession = false
        guard let device, device.hasOpenSession else {
            phase = .closed
            return
        }
        Log.write("切断: セッションを閉じる")
        resetSession()
        phase = .closed
        device.requestCloseSession(options: nil) { error in
            if let error { Log.write("  セッションを閉じる際のエラー: \(error.localizedDescription)") }
        }
    }

    /// ImageCaptureCore のカメラがいないときの待ち方
    private var waitingPhase: Phase {
        usb.camera.map { .detected($0.name, since: $0.since) } ?? .searching
    }

    private func usbChanged() {
        guard wantsSession, device == nil else { return }
        phase = waitingPhase
    }

    private func begin(_ device: ICCameraDevice) {
        Log.startSession()
        let name = device.name ?? String(localized: "カメラ")
        Log.write("接続: \(name)（ImageCaptureCore、ptpcamerad 経由）")
        resetSession()
        phase = .opening(name)
        device.delegate = self
        device.requestOpenSession()
    }

    private func resetSession() {
        camera = nil
        openedAt = nil
        clockDrift = nil
        classifyReady = false
        pendingFiles = []
        seenNames = []
        queue = []
        cardFiles = [:]
        cardSettled = false
        cardExpected = nil
        frameworkCatalogDone = false
        settleTask?.cancel()
        notifyCardChanged()
    }

    // MARK: カードの一覧

    private func cardFilesArrived(_ files: [ICCameraFile]) {
        for file in files {
            guard let name = file.name else { continue }
            cardFiles["\(file.parentFolder?.name ?? "")/\(name)"] = file
        }
        scheduleSettle()
        notifyCardChanged()
    }

    /// 完了の合図のあと、ファイルの到着が途切れたら出そろったとみなす。
    ///
    /// 電源を入れた直後は、合図のあとも 0.1 秒おきにファイルが届き続ける。
    /// 途切れただけで決めると、ほかの命令が割り込んで間が空いたときに早まる（6 件で「出そろった」になった）ので、
    /// 接続時に数えたオブジェクト数（フォルダのぶん少し多い）にほぼ届くまでは待つ（iOS 版と同じ判定）。
    /// 数えられなかったとき、数が合わないまま長く途切れたときは、時間で決める
    private func scheduleSettle() {
        guard frameworkCatalogDone, !cardSettled else { return }
        settleTask?.cancel()
        settleTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(1500))
            guard let self, !Task.isCancelled else { return }
            if let expected = self.cardExpected, self.cardFiles.count + 10 < expected {
                // まだ届いていないはず。到着が止まったままなら、しばらく待ってから打ち切る
                try? await Task.sleep(for: .seconds(8))
                guard !Task.isCancelled else { return }
                Log.write("カードの一覧: \(expected) 件のうち \(self.cardFiles.count) 件で到着が止まった")
            }
            self.cardSettled = true
            Log.write("カードの一覧が出そろった: \(self.cardFiles.count) 件（数えたオブジェクト \(self.cardExpected.map(String.init) ?? "?") 件）")
            self.notifyCardChanged()
        }
    }

    /// カード内のオブジェクトを数える（GetObjectHandles。全ストレージ・全形式・全階層）
    private func countObjects(_ camera: PTPCamera) async {
        guard let data = try? await camera.send(.getObjectHandles, params: [0xFFFF_FFFF, 0, 0]) else { return }
        var r = PTPReader(data)
        guard let n = r.read(UInt32.self) else { return }
        cardExpected = Int(n)
        Log.write("カード内のオブジェクト \(n) 件")
        notifyCardChanged()
    }

    /// 1 件ずつ知らせると画面の描き直しが追いつかないので、0.3 秒ぶんまとめる
    private func notifyCardChanged() {
        guard cardNotifyTask == nil else { return }
        cardNotifyTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard let self else { return }
            self.cardNotifyTask = nil
            self.onCardChanged?()
        }
    }

    // MARK: 接続後に撮ったカットか

    /// 時計を合わせる前でも判定できるよう、接続時に読んだずれを織り込む。
    /// カメラが遅れていれば基準を下げ、進んでいれば Mac の時刻を基準にする（iOS 版と同じ）
    private func isShotAfterOpening(_ file: ICCameraFile) -> Bool {
        guard let taken = file.creationDate, let since = openedAt else { return false }
        return taken >= since.addingTimeInterval(-max(clockDrift ?? 0, 0) - 2)
    }

    private func ingest(_ files: [ICCameraFile]) {
        for file in files {
            guard let name = file.name, !seenNames.contains(name) else { continue }
            seenNames.insert(name)
            guard isShotAfterOpening(file), !savedFiles.contains("\(name)#\(file.fileSize)") else { continue }
            Log.write("撮影ファイル: \(name) \(file.fileSize) バイト")
            queue.append(file)
        }
        drainQueue()
    }

    // MARK: 保存

    private func drainQueue() {
        guard !draining, !queue.isEmpty else { return }
        draining = true
        Task {
            while !queue.isEmpty {
                let file = queue.removeFirst()
                await save(file)
            }
            draining = false
        }
    }

    private func save(_ file: ICCameraFile) async {
        let name = file.name ?? "?"
        switch await download(file, into: destination, deleteFromCard: deleteAfterDownload) {
        case .success(let url):
            savedFiles.insert("\(name)#\(file.fileSize)")
            onFileSaved?(url, file)
        case .failure(let reason):
            // ここを黙って握り潰すと、撮ったコマが消えたことに誰も気づかない
            fail(name, reason.message)
        }
    }

    struct DownloadFailure: Error {
        let message: String
    }

    /// カードのファイルを 1 つ、フォルダへ落とす。同名があれば連番を付ける。
    /// テザーの保存とカードからの取り込みの両方で使う
    func download(_ file: ICCameraFile, into directory: URL, deleteFromCard: Bool = false) async -> Result<URL, DownloadFailure> {
        let name = file.name ?? "?"
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            return .failure(DownloadFailure(message: String(localized: "保存先を作成できません（\(directory.path)）: \(error.localizedDescription)")))
        }
        // 同名衝突（カード入れ替えでファイル番号が巻き戻る等）を避ける
        var target = directory.appendingPathComponent(name)
        let base = target.deletingPathExtension().lastPathComponent
        let ext = target.pathExtension
        var n = 1
        while fm.fileExists(atPath: target.path) {
            target = directory.appendingPathComponent("\(base)-\(n).\(ext)")
            n += 1
        }

        downloading += 1
        defer { downloading -= 1 }
        let started = Date()
        var options: [ICDownloadOption: Any] = [
            .downloadsDirectoryURL: directory,
            .saveAsFilename: target.lastPathComponent,
            .overwrite: false,
        ]
        if deleteFromCard { options[.deleteAfterSuccessfulDownload] = true }

        let result: Result<URL, Error> = await withCheckedContinuation { cont in
            file.requestDownload(options: options) { filename, error in
                if let error {
                    cont.resume(returning: .failure(error))
                } else {
                    cont.resume(returning: .success(directory.appendingPathComponent(filename ?? target.lastPathComponent)))
                }
            }
        }
        switch result {
        case .success(let url):
            // ImageCaptureCore は 0600 で書き出す。libgphoto2 版と同じく、ほかのアカウントや NAS へのコピーでも読めるようにする
            try? fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
            Log.write(String(format: "保存: %@ %.1f 秒", url.lastPathComponent, Date().timeIntervalSince(started)))
            return .success(url)
        case .failure(let error):
            return .failure(DownloadFailure(message: String(localized: "保存できません（\(target.path)）: \(error.localizedDescription)")))
        }
    }

    private func fail(_ name: String, _ reason: String) {
        Log.write("転送失敗 \(name): \(reason)")
        onDownloadFailed?(name, reason)
    }
}

// MARK: - デバイス検出

extension CameraLink: ICDeviceBrowserDelegate {
    nonisolated func deviceBrowser(_ browser: ICDeviceBrowser, didAdd device: ICDevice, moreComing: Bool) {
        Task { @MainActor in
            guard self.device == nil, let camera = device as? ICCameraDevice else { return }
            self.device = camera
            if let since = self.usb.camera?.since {
                Log.write(String(format: "カメラを検出: %@（USB に現れてから %.1f 秒）", camera.name ?? "?", Date().timeIntervalSince(since)))
            } else {
                Log.write("カメラを検出: \(camera.name ?? "?")")
            }
            if self.wantsSession { self.begin(camera) }
        }
    }

    nonisolated func deviceBrowser(_ browser: ICDeviceBrowser, didRemove device: ICDevice, moreGoing: Bool) {
        Task { @MainActor in
            guard device === self.device else { return }
            Log.write("カメラが外れた")
            self.device = nil
            let wasOpen: Bool
            switch self.phase {
            case .closed, .searching, .detected: wasOpen = false
            default: wasOpen = true
            }
            self.resetSession()
            self.phase = self.wantsSession ? self.waitingPhase : .closed
            if wasOpen { self.onLost?(String(localized: "カメラが取り外されました")) }
        }
    }
}

// MARK: - セッションとファイル

extension CameraLink: ICCameraDeviceDelegate {

    nonisolated func device(_ device: ICDevice, didOpenSessionWithError error: (any Error)?) {
        let opened = Date()
        Task { @MainActor in
            guard device === self.device, let cameraDevice = device as? ICCameraDevice else { return }
            let name = device.name ?? String(localized: "カメラ")
            if let error {
                Log.write("セッションを開けない: \(error.localizedDescription)")
                self.phase = .closed
                self.onLost?(String(localized: "カメラに接続できません: \(error.localizedDescription)"))
                return
            }
            self.openedAt = opened
            self.phase = .preparing(name)
            let camera = PTPCamera(device: cameraDevice) { Log.write($0) }
            self.camera = camera

            // 電源を入れた直後は、カードの下調べが終わるまでここで待たされる。
            // DeviceInfo を先に読む（Nikon 1 は名乗っていない命令を送ると通信ごと固まるため）
            var info: DeviceInfo?
            for attempt in 1...4 where info == nil {
                if attempt > 1 { try? await Task.sleep(for: .milliseconds(500)) }
                info = await camera.readDeviceInfo()
            }
            guard self.camera === camera else { return }
            if let info {
                Log.write("DeviceInfo: \(info.manufacturer) \(info.model) \(info.version) S/N \(info.serialNumber)"
                          + (camera.capabilities?.isNikon1 == true ? "（Nikon 1）" : ""))
            } else {
                Log.write("DeviceInfo を読めない。独自命令は送らない")
            }
            if let clock = await camera.cameraClock() {
                self.clockDrift = Date().timeIntervalSince(clock)
            }
            await self.countObjects(camera)
            Log.write(String(format: "準備完了 %.1f 秒（時計のずれ %@）", Date().timeIntervalSince(opened),
                             self.clockDrift.map { String(format: "%.1f 秒", $0) } ?? "不明"))
            guard self.camera === camera else { return }
            if camera.isNikon, camera.capabilities?.isNikon1 != true {
                // ライブビュー中にアプリが落ちたりケーブルが抜けたりすると、記録先が SDRAM のまま残り
                // 本体で撮ってもカードに保存されなくなる。つないだら確かめて戻す
                await NikonLiveView.restoreIfInterrupted(camera)
            }
            self.classifyReady = true
            let held = self.pendingFiles
            self.pendingFiles = []
            self.ingest(held)
            self.phase = .ready(name)
            self.onReady?(camera)
        }
    }

    nonisolated func device(_ device: ICDevice, didCloseSessionWithError error: (any Error)?) {
        Task { @MainActor in
            guard device === self.device else { return }
            Log.write("セッションが閉じた")
            let unexpected = self.phase != .closed
            self.resetSession()
            self.phase = .closed
            if unexpected { self.onLost?(error.map { $0.localizedDescription }) }
        }
    }

    nonisolated func didRemove(_ device: ICDevice) {}

    nonisolated func cameraDevice(_ camera: ICCameraDevice, didAdd items: [ICCameraItem]) {
        let files = items.compactMap { $0 as? ICCameraFile }
        Task { @MainActor in
            guard camera === self.device, self.openedAt != nil else { return }
            self.cardFilesArrived(files)
            if self.classifyReady {
                self.ingest(files)
            } else {
                self.pendingFiles.append(contentsOf: files)
            }
        }
    }

    nonisolated func cameraDevice(_ camera: ICCameraDevice, didReceivePTPEvent eventData: Data) {
        guard let event = PTPEvent.container(eventData) else { return }
        Task { @MainActor in
            guard camera === self.device else { return }
            self.onPTPEvent?(event)
        }
    }

    nonisolated func deviceDidBecomeReady(withCompleteContentCatalog device: ICCameraDevice) {
        Task { @MainActor in
            guard device === self.device else { return }
            Log.write("一覧の完了通知")
            self.frameworkCatalogDone = true
            // ファイルが 1 件も来ないカード（空）でも、ここから数え始めるので出そろったと判定できる
            self.scheduleSettle()
        }
    }

    nonisolated func cameraDevice(_ camera: ICCameraDevice, didRemove items: [ICCameraItem]) {}
    nonisolated func cameraDevice(_ camera: ICCameraDevice, didRenameItems items: [ICCameraItem]) {}
    nonisolated func cameraDeviceDidChangeCapability(_ camera: ICCameraDevice) {}
    nonisolated func cameraDevice(_ camera: ICCameraDevice, didReceiveThumbnail thumbnail: CGImage?, for item: ICCameraItem, error: (any Error)?) {}
    nonisolated func cameraDevice(_ camera: ICCameraDevice, didReceiveMetadata metadata: [AnyHashable: Any]?, for item: ICCameraItem, error: (any Error)?) {}
    nonisolated func cameraDeviceDidEnableAccessRestriction(_ device: ICDevice) {}
    nonisolated func cameraDeviceDidRemoveAccessRestriction(_ device: ICDevice) {}
}
