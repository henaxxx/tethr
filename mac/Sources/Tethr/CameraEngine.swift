import Foundation
import AppKit
import CGPhoto

// MARK: - エラー

enum CameraError: LocalizedError {
    case driversMissing
    case gp(Int32, String)
    case notConnected

    var errorDescription: String? {
        switch self {
        case .driversMissing:
            return String(localized: "libgphoto2 のドライバが見つかりません。アプリを入れ直してください。")
        case .notConnected:
            return String(localized: "カメラが接続されていません。")
        case .gp(let code, let op):
            let msg = String(cString: gp_result_as_string(code))
            if code == GP_ERROR_MODEL_NOT_FOUND {
                return String(localized: "カメラが見つかりません。USB 接続と電源を確認してください。(\(op))")
            }
            if code == GP_ERROR_TIMEOUT {
                return String(localized: "カメラが応答しません。USB ポートをリセットして再試行します。(\(op))")
            }
            if code == GP_ERROR_IO_USB_CLAIM {
                return String(localized: "USB を掴めません。macOS の ptpcamerad が握ったままの可能性があります。(\(op))")
            }
            return "\(op): \(msg) [\(code)]"
        }
    }
}

// MARK: - イベント

enum CameraEvent {
    case fileArrived(URL)          // 撮影ファイルを保存し終えた
    case property(String, String)  // カメラ側プロパティの変化 (名前, 値)
    case captureComplete
    case previewFrame(NSImage)     // ライブビューの1コマ
    case downloadFailed(name: String, reason: String)
    case disconnected(String)      // 切断理由
}

// MARK: - エンジン

/// libgphoto2 は 1 カメラにつきスレッドセーフではないため、
/// 専用のシリアルキューが Camera* を単独で所有する。
/// UI からの操作もイベント待ちも、すべてこのキュー上で直列化される。
final class CameraEngine {

    private let queue = DispatchQueue(label: "app.tethr.camera", qos: .userInitiated)
    private var camera: UnsafeMutablePointer<Camera>?
    private var context: OpaquePointer?
    private var pumping = false
    private var previewing = false
    /// 表示が追いつかないうちに次のコマを積まないための目印
    private var frameInFlight = false
    /// リモート撮影で奪った制御権を、ファイル回収後に返すための目印
    private var releaseControlPending = false
    private var releaseControlDeadline: Date?

    /// イベント通知。メインスレッドで呼ばれる。
    var onEvent: ((CameraEvent) -> Void)?

    /// 撮影ファイルの保存先。
    var destination: URL = FileManager.default
        .homeDirectoryForCurrentUser.appendingPathComponent("Pictures/Tethr")

    /// 転送後にカメラ側のファイルを消すか。既定は残す。
    var deleteAfterDownload = false

    // MARK: ドライバ探索

    /// CAMLIBS / IOLIBS をハードコードせず実行時に解決する。
    /// libgphoto2 はパスにバージョン番号を含むため、決め打ちすると更新で壊れる。
    private static func newestVersionDir(_ base: String) -> String? {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(atPath: base) else { return nil }

        let versionDirs = entries.filter { name in
            // このディレクトリにはバージョン番号のフォルダ以外に
            // print-camera-list のような実行ファイルも同居している。
            // 単に名前順で最後を取ると、そちらを掴んでドライバが
            // 1 つも読み込まれない状態になる。
            guard name.range(of: "^[0-9]+(\\.[0-9]+)*$", options: .regularExpression) != nil else {
                return false
            }
            var isDir: ObjCBool = false
            let full = (base as NSString).appendingPathComponent(name)
            guard fm.fileExists(atPath: full, isDirectory: &isDir), isDir.boolValue else { return false }
            // ドライバ本体が実在することまで確かめる
            let contents = (try? fm.contentsOfDirectory(atPath: full)) ?? []
            return contents.contains { $0.hasSuffix(".so") }
        }

        let sorted = versionDirs.sorted { $0.compare($1, options: .numeric) == .orderedAscending }
        guard let newest = sorted.last else { return nil }
        return (base as NSString).appendingPathComponent(newest)
    }

    private static var loggingHooked = false

    private static func hookGPLog() {
        guard !loggingHooked else { return }
        loggingHooked = true
        gp_log_add_func(GP_LOG_ERROR, { _, domain, str, _ in
            let d = domain.map { String(cString: $0) } ?? "?"
            let s = str.map { String(cString: $0) } ?? ""
            Log.write("  gp[\(d)] \(s)")
        }, nil)
    }

    /// ドライバ一式が入っているディレクトリかどうか
    private static func hasDrivers(_ path: String) -> Bool {
        let contents = (try? FileManager.default.contentsOfDirectory(atPath: path)) ?? []
        return contents.contains { $0.hasSuffix(".so") }
    }

    private static func configureDriverPaths() throws {
        // アプリに同梱したドライバを最優先で使う。
        // これがあれば Homebrew を入れていない Mac でも動作する。
        if let plugins = Bundle.main.builtInPlugInsURL {
            let cam = plugins.appendingPathComponent("camlibs").path
            let io = plugins.appendingPathComponent("iolibs").path
            if hasDrivers(cam), hasDrivers(io) {
                setenv("CAMLIBS", cam, 1)
                setenv("IOLIBS", io, 1)
                Log.write("ドライバ: アプリ同梱版を使用")
                return
            }
        }

        // 同梱が無い場合（開発中のビルドなど）は Homebrew を探す
        for prefix in ["/opt/homebrew", "/usr/local"] {
            guard
                let cam = newestVersionDir("\(prefix)/lib/libgphoto2"),
                let io  = newestVersionDir("\(prefix)/lib/libgphoto2_port")
            else { continue }
            setenv("CAMLIBS", cam, 1)
            setenv("IOLIBS", io, 1)
            Log.write("ドライバ CAMLIBS=\(cam)")
            Log.write("ドライバ IOLIBS=\(io)")
            return
        }
        throw CameraError.driversMissing
    }

    /// macOS の ptpcamerad は接続を検知すると自動でカメラを掴む。
    /// SIP により launchd から無効化できないため、接続前に落とす。
    /// 一度こちらが USB を掴めば、以後は奪い返されない。
    private static func evictPTPCameraDaemon() {
        for name in ["ptpcamerad", "PTPCamera", "icdd"] {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
            p.arguments = ["-9", name]
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            do {
                try p.run()
                p.waitUntilExit()
                Log.write("  killall \(name) → status \(p.terminationStatus)")
            } catch {
                Log.write("  killall \(name) 実行不可: \(error.localizedDescription)")
            }
        }
        Thread.sleep(forTimeInterval: 0.6)
    }

    // MARK: 接続

    private var portInfoList: OpaquePointer?
    private var detectedModel = "カメラ"
    private var detectedPort = ""

    /// 機種とポートを明示して開く。
    /// gp_camera_init の自動選択は ptpcamerad との競合時に
    /// 曖昧なエラーを返すため、CLI と同じく明示指定する。
    private func openCameraSync() throws -> (UnsafeMutablePointer<Camera>, OpaquePointer) {
        guard let ctx = gp_context_new() else { throw CameraError.gp(GP_ERROR, "gp_context_new") }

        var list: OpaquePointer?
        gp_list_new(&list)
        defer { gp_list_free(list) }

        let n = gp_camera_autodetect(list, ctx)
        Log.write("  autodetect → \(n) 台")
        guard n > 0 else {
            gp_context_unref(ctx)
            throw CameraError.gp(GP_ERROR_MODEL_NOT_FOUND, "autodetect")
        }

        var nameC: UnsafePointer<CChar>?
        var portC: UnsafePointer<CChar>?
        gp_list_get_name(list, 0, &nameC)
        gp_list_get_value(list, 0, &portC)
        guard let nameC, let portC else {
            gp_context_unref(ctx)
            throw CameraError.gp(GP_ERROR, "gp_list_get")
        }
        let model = String(cString: nameC)
        let port = String(cString: portC)
        detectedModel = model
        detectedPort = port
        Log.write("  検出: \(model) @ \(port)")

        var camOpt: UnsafeMutablePointer<Camera>?
        guard gp_camera_new(&camOpt) >= GP_OK, let cam = camOpt else {
            gp_context_unref(ctx)
            throw CameraError.gp(GP_ERROR, "gp_camera_new")
        }

        var al: OpaquePointer?
        gp_abilities_list_new(&al)
        gp_abilities_list_load(al, ctx)
        let mi = gp_abilities_list_lookup_model(al, model)
        if mi >= GP_OK {
            var ab = CameraAbilities()
            gp_abilities_list_get_abilities(al, mi, &ab)
            gp_camera_set_abilities(cam, ab)
        }
        gp_abilities_list_free(al)

        // GPPortInfo はリスト本体のメモリを指すため、リストは接続中ずっと保持する
        if portInfoList == nil {
            var pl: OpaquePointer?
            gp_port_info_list_new(&pl)
            gp_port_info_list_load(pl)
            portInfoList = pl
        }
        let idx = gp_port_info_list_lookup_path(portInfoList, port)
        if idx >= GP_OK {
            var pi: GPPortInfo?
            gp_port_info_list_get_info(portInfoList, idx, &pi)
            gp_camera_set_port_info(cam, pi)
        }

        let r = gp_camera_init(cam, ctx)
        Log.write("  gp_camera_init → \(r) (\(String(cString: gp_result_as_string(r))))")
        guard r >= GP_OK else {
            // 失敗時も必ず exit を通す。ここを飛ばすとカメラ側に
            // PTP セッションが残り、本体の電源を入れ直すまで復帰しない。
            gp_camera_exit(cam, ctx)
            gp_camera_unref(cam)
            gp_context_unref(ctx)
            throw CameraError.gp(r, "gp_camera_init")
        }
        return (cam, ctx)
    }

    /// USB ポートをリセットする。
    /// カメラ側に PTP セッションが半開きのまま残ると、以後の転送が
    /// すべてタイムアウトする。この状態はプロセスを消しても解けず、
    /// USB の再列挙が要る。ケーブル抜き差しと等価な操作をここで行う。
    private func resetPortSync() {
        guard !detectedPort.isEmpty, let pl = portInfoList else { return }
        let idx = gp_port_info_list_lookup_path(pl, detectedPort)
        guard idx >= GP_OK else { return }
        var pi: GPPortInfo?
        gp_port_info_list_get_info(pl, idx, &pi)

        var portOpt: UnsafeMutablePointer<GPPort>?
        guard gp_port_new(&portOpt) >= GP_OK, let port = portOpt else { return }
        defer { gp_port_free(port) }
        gp_port_set_info(port, pi)
        if gp_port_open(port) >= GP_OK {
            gp_port_reset(port)
            gp_port_close(port)
        }
        Thread.sleep(forTimeInterval: 2.0)
    }

    func connect(completion: @escaping (Result<String, Error>) -> Void) {
        queue.async {
            do {
                Log.startSession()
                Self.hookGPLog()
                try Self.configureDriverPaths()
                var lastError: Error?
                for attempt in 1...5 {
                    Log.write("接続 試行 \(attempt)/5")
                    Self.evictPTPCameraDaemon()
                    if attempt > 1 {
                        self.resetPortSync()
                        Self.evictPTPCameraDaemon()
                    }
                    do {
                        let (cam, ctx) = try self.openCameraSync()
                        self.camera = cam
                        self.context = ctx
                        self.preferCardStorage()
                        let model = self.readConfigSync("cameramodel") ?? self.detectedModel
                        self.startPumping()
                        Log.write("✅ 接続成功: \(model)")
                        DispatchQueue.main.async { completion(.success(model)) }
                        return
                    } catch {
                        lastError = error
                        Log.write("  失敗: \(error.localizedDescription)")
                        Thread.sleep(forTimeInterval: Double(attempt))
                    }
                }
                throw lastError ?? CameraError.notConnected
            } catch {
                DispatchQueue.main.async { completion(.failure(error)) }
            }
        }
    }

    func disconnect() {
        queue.async {
            self.pumping = false
            if self.previewing {
                self.previewing = false
                _ = self.setConfigSync("viewfinder", "0")
            }
            if let cam = self.camera {
                gp_camera_exit(cam, self.context)
                gp_camera_unref(cam)
            }
            if let ctx = self.context { gp_context_unref(ctx) }
            self.camera = nil
            self.context = nil
        }
    }

    // MARK: イベントループ

    private func startPumping() {
        pumping = true
        queue.async { self.pump() }
    }

    /// 1 回あたり最大 200ms だけブロックし、すぐキューを解放する。
    /// これで UI からのコマンドがイベント待ちに割り込める。
    private func pump() {
        guard pumping, let cam = camera, let ctx = context else { return }

        // 撮影ファイルが届かないまま時間切れになった場合も制御権は返す。
        // ここを怠ると本体がロックされたままになる。
        if releaseControlPending, let deadline = releaseControlDeadline, Date() > deadline {
            releaseControlPending = false
            releaseControlDeadline = nil
            _ = setConfigSync("controlmode", "0")
            Log.write("撮影ファイル未着のまま時間切れ。制御権を本体へ返しました")
        }

        if previewing { grabPreviewFrame() }

        // ライブビュー中はコマ取りで時間を使うので、イベント待ちは最小限にする。
        // 止まっているときは 200ms 待って CPU を遊ばせる。
        let timeout: Int32 = previewing ? 1 : 200

        var type = GP_EVENT_UNKNOWN
        var data: UnsafeMutableRawPointer?
        let r = gp_camera_wait_for_event(cam, timeout, &type, &data, ctx)

        if r < GP_OK {
            // I/O エラーはケーブル抜けや電源断。ループを畳んで UI に伝える。
            if r == GP_ERROR_IO || r == GP_ERROR_IO_USB_CLAIM {
                pumping = false
                let msg = String(cString: gp_result_as_string(r))
                DispatchQueue.main.async { self.onEvent?(.disconnected(msg)) }
                if let d = data { free(d) }
                return
            }
        } else {
            handle(type: type, data: data)
        }

        if let d = data { free(d) }
        queue.async { self.pump() }
    }

    private func handle(type: CameraEventType, data: UnsafeMutableRawPointer?) {
        if type == GP_EVENT_FILE_ADDED, let data {
            let fp = data.assumingMemoryBound(to: CameraFilePath.self)
            guard
                let nameC = tethr_filepath_name(fp),
                let folderC = tethr_filepath_folder(fp)
            else { return }
            let name = String(cString: nameC)
            let folder = String(cString: folderC)
            if let url = download(folder: folder, name: name) {
                DispatchQueue.main.async { self.onEvent?(.fileArrived(url)) }
            }
            // 撮影データを取り切ってから返す。先に返すと転送が中断しかねない。
            if releaseControlPending {
                releaseControlPending = false
                releaseControlDeadline = nil
                _ = setConfigSync("controlmode", "0")
                Log.write("リモート撮影後、制御権を本体へ返しました")
            }
        } else if type == GP_EVENT_CAPTURE_COMPLETE {
            DispatchQueue.main.async { self.onEvent?(.captureComplete) }
        } else if type == GP_EVENT_UNKNOWN, let data {
            guard let s = tethr_event_string(data) else { return }
            let raw = String(cString: s)
            // 例: PTP Property 0000d1b1 changed, "lightmeter" to "-28.000000"
            if let (key, value) = Self.parseProperty(raw) {
                DispatchQueue.main.async { self.onEvent?(.property(key, value)) }
            }
        }
    }

    private static func parseProperty(_ raw: String) -> (String, String)? {
        guard let re = try? NSRegularExpression(pattern: #""([^"]+)"\s+to\s+"([^"]*)""#) else { return nil }
        let ns = raw as NSString
        guard let m = re.firstMatch(in: raw, range: NSRange(location: 0, length: ns.length)),
              m.numberOfRanges == 3 else { return nil }
        return (ns.substring(with: m.range(at: 1)), ns.substring(with: m.range(at: 2)))
    }

    // MARK: 転送

    private func download(folder: String, name: String) -> URL? {
        guard let cam = camera, let ctx = context else { return nil }

        let fm = FileManager.default
        do {
            try fm.createDirectory(at: destination, withIntermediateDirectories: true)
        } catch {
            fail(name, "保存先を作成できません（\(destination.path)）: \(error.localizedDescription)")
            return nil
        }

        var target = destination.appendingPathComponent(name)
        // 同名衝突（カード入れ替えでファイル番号が巻き戻る等）を避ける
        var n = 1
        let base = target.deletingPathExtension().lastPathComponent
        let ext = target.pathExtension
        while fm.fileExists(atPath: target.path) {
            target = destination.appendingPathComponent("\(base)-\(n).\(ext)")
            n += 1
        }

        var fileOpt: OpaquePointer?
        guard gp_file_new(&fileOpt) >= GP_OK, let file = fileOpt else {
            fail(name, "メモリを確保できません")
            return nil
        }
        defer { gp_file_unref(file) }

        var r = gp_camera_file_get(cam, folder, name, GP_FILE_TYPE_NORMAL, file, ctx)
        guard r >= GP_OK else {
            fail(name, "カメラから読み出せません: \(String(cString: gp_result_as_string(r)))")
            return nil
        }

        r = gp_file_save(file, target.path)
        guard r >= GP_OK else {
            // ここを黙って握り潰すと、撮ったコマが消えたことに誰も気づかない
            fail(name, "保存できません（\(target.path)）: \(String(cString: gp_result_as_string(r)))")
            return nil
        }

        if deleteAfterDownload {
            gp_camera_file_delete(cam, folder, name, ctx)
        }
        return target
    }

    private func fail(_ name: String, _ reason: String) {
        Log.write("転送失敗 \(name): \(reason)")
        DispatchQueue.main.async { self.onEvent?(.downloadFailed(name: name, reason: reason)) }
    }

    // MARK: 撮影

    /// シャッターを切る。ファイルはイベントループ側で拾うので、ここでは待たない。
    func triggerCapture(completion: @escaping (Error?) -> Void) {
        queue.async {
            guard let cam = self.camera, let ctx = self.context else {
                DispatchQueue.main.async { completion(CameraError.notConnected) }
                return
            }
            let r = self.pausingPreview { gp_camera_trigger_capture(cam, ctx) }
            if r >= GP_OK {
                self.releaseControlPending = true
                self.releaseControlDeadline = Date().addingTimeInterval(6)
            }
            let err: Error? = r >= GP_OK ? nil : CameraError.gp(r, "gp_camera_trigger_capture")
            DispatchQueue.main.async { completion(err) }
        }
    }

    /// リモート撮影の保存先をカードにする。
    ///
    /// libgphoto2 の既定は Internal RAM で、撮影データがカメラ内に残らない。
    /// ホストへの転送が失敗すればその写真は失われるうえ、
    /// ファイル名も capt0000.nef のような汎用名になり、
    /// カメラ側に記録が無いので背面液晶での再生もできない。
    /// 本体シャッターで撮った場合と同じ挙動に揃える。
    ///
    /// 選択肢のラベルは機種で揺れるので、"card" を含むものを探す。
    private func preferCardStorage() {
        let choices = readChoicesSync("capturetarget")
        guard let card = choices.first(where: { $0.lowercased().contains("card") }) else {
            Log.write("capturetarget にカード相当の選択肢なし: \(choices)")
            return
        }
        let r = setConfigSync("capturetarget", card)
        Log.write("リモート撮影の保存先を「\(card)」に設定: \(r)")
    }

    /// カメラ本体に制御権を返す。
    ///
    /// Nikon 機では gp_camera_trigger_capture が内部で制御権を奪い、
    /// そのまま返さない。結果として上面液晶が PC 表示のままになり、
    /// シャッターもコマンドダイヤルも本体側で効かなくなる。
    /// controlmode に 0 を書くと本体へ戻る。
    ///
    /// 他社機にこのキーは無いので、失敗しても無視してよい。
    func releaseCameraControl(completion: ((Error?) -> Void)? = nil) {
        queue.async {
            guard self.camera != nil else {
                DispatchQueue.main.async { completion?(CameraError.notConnected) }
                return
            }
            let r = self.setConfigSync("controlmode", "0")
            Log.write("制御権を本体へ返却: \(r) (\(String(cString: gp_result_as_string(r))))")
            let err: Error? = r >= GP_OK ? nil : CameraError.gp(r, "controlmode=0")
            DispatchQueue.main.async { completion?(err) }
        }
    }

    /// ライブビューの開始・停止。
    ///
    /// viewfinder=1 はレリーズモードダイヤルが Lv のとき拒否されるが、
    /// capture_preview 側が内部でライブビューを開くため、
    /// 失敗しても映像は取れる。よって結果は見ずに続行する。
    /// 停止時の viewfinder=0 は必ず送る。これを省くとミラーが上がったまま残り、
    /// センサーが熱を持ち、ファインダーも塞がったままになる。
    func setLiveView(_ on: Bool, completion: @escaping (Error?) -> Void) {
        queue.async {
            guard self.camera != nil else {
                DispatchQueue.main.async { completion(CameraError.notConnected) }
                return
            }
            if on {
                _ = self.setConfigSync("viewfinder", "1")
                self.previewing = true
                Log.write("ライブビュー開始")
            } else {
                self.previewing = false
                self.frameInFlight = false
                _ = self.setConfigSync("viewfinder", "0")
                Log.write("ライブビュー停止")
            }
            DispatchQueue.main.async { completion(nil) }
        }
    }

    /// ライブビューのコマ取りを止めて処理を行い、終わったら元に戻す。
    /// コマ取りの合間にコマンドを差し込むとカメラが取りこぼすことがある。
    /// AF や撮影のように時間のかかる操作は、コマ取りを止めてから送る。
    private func pausingPreview<T>(_ body: () -> T) -> T {
        let was = previewing
        previewing = false
        defer { previewing = was }
        return body()
    }

    private func grabPreviewFrame() {
        guard let cam = camera, let ctx = context, !frameInFlight else { return }

        var fileOpt: OpaquePointer?
        guard gp_file_new(&fileOpt) >= GP_OK, let file = fileOpt else { return }
        defer { gp_file_unref(file) }

        guard gp_camera_capture_preview(cam, file, ctx) >= GP_OK else { return }

        var ptr: UnsafePointer<CChar>?
        var size: UInt = 0
        guard gp_file_get_data_and_size(file, &ptr, &size) >= GP_OK,
              let ptr, size > 0 else { return }

        let data = Data(bytes: ptr, count: Int(size))
        guard let image = NSImage(data: data) else { return }

        frameInFlight = true
        DispatchQueue.main.async {
            self.onEvent?(.previewFrame(image))
            self.queue.async { self.frameInFlight = false }
        }
    }

    /// AF を駆動する。シャッター半押しに相当する。
    /// autofocusdrive は TOGGLE の「アクション」ウィジェットで、
    /// 1 を書き込むと AF が走り、完了（または失敗）まで応答が返らない。
    /// ライブビューは不要。合焦しなければエラーが返る。
    func driveAutofocus(completion: @escaping (Error?) -> Void) {
        queue.async {
            guard self.camera != nil else {
                DispatchQueue.main.async { completion(CameraError.notConnected) }
                return
            }
            let live = self.previewing
            let r = self.pausingPreview { self.setConfigSync("autofocusdrive", "1") }
            Log.write("AF: 結果 \(r) (\(String(cString: gp_result_as_string(r))))"
                      + (live ? " / ライブビュー中" : ""))
            let err: Error? = r >= GP_OK ? nil : CameraError.gp(r, "autofocusdrive")
            DispatchQueue.main.async { completion(err) }
        }
    }

    // MARK: 設定の読み書き

    private func readConfigSync(_ name: String) -> String? {
        readConfigDetailSync(name)?.value
    }

    /// 値と書き込み可否をまとめて取る。別々に読むと PTP の往復が倍になる。
    private func readConfigDetailSync(_ name: String) -> (value: String, readonly: Bool)? {
        guard let cam = camera, let ctx = context else { return nil }
        var w: OpaquePointer?
        guard gp_camera_get_single_config(cam, name, &w, ctx) >= GP_OK, let w else { return nil }
        defer { gp_widget_free(w) }
        // 型の取り違えでクラッシュしないよう、値の取り出しは C 側に任せる
        var buf = [CChar](repeating: 0, count: 1024)
        guard tethr_widget_value_string(w, &buf, Int32(buf.count)) >= GP_OK else { return nil }
        let value = buf.withUnsafeBufferPointer { ptr in
            ptr.baseAddress.map { String(cString: $0) }
        }
        guard let value else { return nil }
        return (value, tethr_widget_readonly(w) == 1)
    }

    private func readChoicesSync(_ name: String) -> [String] {
        guard let cam = camera, let ctx = context else { return [] }
        var w: OpaquePointer?
        guard gp_camera_get_single_config(cam, name, &w, ctx) >= GP_OK, let w else { return [] }
        defer { gp_widget_free(w) }
        let count = tethr_widget_choice_count(w)
        guard count > 0 else { return [] }
        return (0..<count).compactMap { i in
            tethr_widget_choice_at(w, i).map { String(cString: $0) }
        }
    }

    /// completion は (値, 読み取り専用だったキーの集合)
    func readConfig(_ names: [String],
                    completion: @escaping ([String: String], Set<String>) -> Void) {
        queue.async {
            var out: [String: String] = [:]
            var readonly: Set<String> = []
            for n in names {
                guard let d = self.readConfigDetailSync(n) else { continue }
                out[n] = d.value
                if d.readonly { readonly.insert(n) }
            }
            DispatchQueue.main.async { completion(out, readonly) }
        }
    }

    func readChoices(_ names: [String], completion: @escaping ([String: [String]]) -> Void) {
        queue.async {
            var out: [String: [String]] = [:]
            for n in names {
                let c = self.readChoicesSync(n)
                if !c.isEmpty { out[n] = c }
            }
            DispatchQueue.main.async { completion(out) }
        }
    }

    /// カメラ設定を1件書き込む。戻り値は libgphoto2 のコード。
    @discardableResult
    private func setConfigSync(_ name: String, _ value: String) -> Int32 {
        guard let cam = camera, let ctx = context else { return GP_ERROR }
        var w: OpaquePointer?
        var r = gp_camera_get_single_config(cam, name, &w, ctx)
        guard r >= GP_OK, let w else { return r }
        defer { gp_widget_free(w) }
        r = tethr_widget_set_from_string(w, value)
        if r >= GP_OK {
            r = gp_camera_set_single_config(cam, name, w, ctx)
        }
        return r
    }

    func writeConfig(_ name: String, value: String, completion: @escaping (Error?) -> Void) {
        queue.async {
            guard self.camera != nil else {
                DispatchQueue.main.async { completion(CameraError.notConnected) }
                return
            }
            let r = self.setConfigSync(name, value)
            var err: Error? = r >= GP_OK ? nil : CameraError.gp(r, "set \(name)=\(value)")

            // 露出モードの変更などでは、設定は通っているのにカメラが
            // 応答を返しきれず PTP Timeout になることがある。
            // 失敗扱いにする前に読み直し、狙った値になっていれば成功とみなす。
            if err != nil {
                Thread.sleep(forTimeInterval: 0.4)
                if let actual = self.readConfigSync(name), actual == value {
                    Log.write("  set \(name)=\(value): エラー応答だが値は反映済み")
                    err = nil
                }
            }
            DispatchQueue.main.async { completion(err) }
        }
    }
}
