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
        /// 開きたいが、カメラが見つからない
        case searching
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
    var onFileSaved: ((URL) -> Void)?
    var onDownloadFailed: ((String, String) -> Void)?

    /// 撮影ファイルの保存先
    var destination: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Pictures/Tethr")
    /// 転送に成功したらカードから消すか
    var deleteAfterDownload = false
    /// 保存中の数。問い合わせを控えるのに使う
    private(set) var downloading = 0

    private let browser = ICDeviceBrowser()
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
    }

    var isReady: Bool {
        if case .ready = phase { return true }
        return false
    }

    // MARK: 接続と切断

    func open() {
        wantsSession = true
        guard let device else {
            phase = .searching
            Log.write("接続: カメラを探しています")
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
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: destination, withIntermediateDirectories: true)
        } catch {
            fail(name, String(localized: "保存先を作成できません（\(destination.path)）: \(error.localizedDescription)"))
            return
        }
        // 同名衝突（カード入れ替えでファイル番号が巻き戻る等）を避ける
        var target = destination.appendingPathComponent(name)
        let base = target.deletingPathExtension().lastPathComponent
        let ext = target.pathExtension
        var n = 1
        while fm.fileExists(atPath: target.path) {
            target = destination.appendingPathComponent("\(base)-\(n).\(ext)")
            n += 1
        }

        downloading += 1
        defer { downloading -= 1 }
        let started = Date()
        var options: [ICDownloadOption: Any] = [
            .downloadsDirectoryURL: destination,
            .saveAsFilename: target.lastPathComponent,
            .overwrite: false,
        ]
        if deleteAfterDownload { options[.deleteAfterSuccessfulDownload] = true }

        let directory = destination
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
            savedFiles.insert("\(name)#\(file.fileSize)")
            Log.write(String(format: "保存: %@ %.1f 秒", url.lastPathComponent, Date().timeIntervalSince(started)))
            onFileSaved?(url)
        case .failure(let error):
            // ここを黙って握り潰すと、撮ったコマが消えたことに誰も気づかない
            fail(name, String(localized: "保存できません（\(target.path)）: \(error.localizedDescription)"))
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
            Log.write("カメラを検出: \(camera.name ?? "?")")
            if self.wantsSession { self.begin(camera) }
        }
    }

    nonisolated func deviceBrowser(_ browser: ICDeviceBrowser, didRemove device: ICDevice, moreGoing: Bool) {
        Task { @MainActor in
            guard device === self.device else { return }
            Log.write("カメラが外れた")
            self.device = nil
            let wasOpen = self.phase != .closed && self.phase != .searching
            self.resetSession()
            self.phase = self.wantsSession ? .searching : .closed
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
        Task { @MainActor in Log.write("一覧の完了通知") }
    }

    nonisolated func cameraDevice(_ camera: ICCameraDevice, didRemove items: [ICCameraItem]) {}
    nonisolated func cameraDevice(_ camera: ICCameraDevice, didRenameItems items: [ICCameraItem]) {}
    nonisolated func cameraDeviceDidChangeCapability(_ camera: ICCameraDevice) {}
    nonisolated func cameraDevice(_ camera: ICCameraDevice, didReceiveThumbnail thumbnail: CGImage?, for item: ICCameraItem, error: (any Error)?) {}
    nonisolated func cameraDevice(_ camera: ICCameraDevice, didReceiveMetadata metadata: [AnyHashable: Any]?, for item: ICCameraItem, error: (any Error)?) {}
    nonisolated func cameraDeviceDidEnableAccessRestriction(_ device: ICDevice) {}
    nonisolated func cameraDeviceDidRemoveAccessRestriction(_ device: ICDevice) {}
}
