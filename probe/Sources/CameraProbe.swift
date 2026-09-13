import Foundation
import ImageCaptureCore
import UIKit

/// iOS 上で ImageCaptureCore が USB カメラに対して何をどこまでできるかを調べる。
///
/// 判定したいのは 3 点。
///   1. カメラを検出できるか（DSLR が見つからないという報告があるため）
///   2. ファイルを列挙・取得できるか
///   3. 生の PTP コマンドを送れるか
///      requestSendPTPCommand は iOS でも「利用可能」と宣言されているが、
///      実行時に ICReturnPTPNotAuthorizedToSendCommand (-21249) で
///      弾かれるという報告がある。ここが通れば撮影制御まで射程に入る。
@MainActor
final class CameraProbe: NSObject, ObservableObject {

    struct Finding: Identifiable {
        let id = UUID()
        let time = Date()
        let text: String
        let ok: Bool?
    }

    @Published private(set) var authorization = "未確認"
    @Published private(set) var devices: [ICDevice] = []
    @Published private(set) var openedName: String?
    @Published private(set) var files: [String] = []
    @Published private(set) var findings: [Finding] = []
    @Published private(set) var browsing = false
    @Published private(set) var liveImage: UIImage?

    private let browser = ICDeviceBrowser()
    private var camera: ICCameraDevice?
    /// 接続速度の計測中だけ入る。デリゲートが各段階の時刻を書き込む。
    fileprivate var clock: TrialClock?
    /// 直前に計測したカメラ。抜き差しでオブジェクトが入れ替わったかを見る
    fileprivate var lastMeasured: ICCameraDevice?
    @Published private(set) var measuring = false

    override init() {
        super.init()
        browser.delegate = self
    }

    private func note(_ text: String, ok: Bool? = nil) {
        findings.insert(Finding(text: text, ok: ok), at: 0)
        let mark = ok == true ? "✅" : ok == false ? "❌" : "  "
        let line = "\(Self.stamp.string(from: Date())) \(mark) \(text)\n"
        // devicectl --console で拾えるよう、バッファされない標準エラーへ
        FileHandle.standardError.write(Data(line.utf8))
        Self.appendLog(line)
    }

    private static let stamp: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss.SSS"; return f
    }()

    /// 検証結果を Documents/verify.log に追記する。Mac から devicectl で吸い出す。
    static let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    private static func appendLog(_ line: String) {
        let url = documents.appendingPathComponent("verify.log")
        if let h = try? FileHandle(forWritingTo: url) {
            h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close()
        } else {
            try? Data(line.utf8).write(to: url)
        }
    }

    // MARK: 1. 検出

    func start() {
        note("認可を要求中…")
        browser.requestContentsAuthorization { [weak self] status in
            Task { @MainActor in
                guard let self else { return }
                self.authorization = String(describing: status)
                let granted = status == .authorized
                self.note("認可: \(status.rawValue)", ok: granted)
                guard granted else {
                    self.note("設定 → プライバシー でカメラへのアクセスを許可してください")
                    return
                }
                // 種別を絞らずに全部見る。DSLR がどの分類で来るか不明なため。
                self.browser.browsedDeviceTypeMask = ICDeviceTypeMask(
                    rawValue: ICDeviceTypeMask.camera.rawValue | ICDeviceLocationTypeMask.local.rawValue
                )!
                self.browser.start()
                self.browsing = true
                self.note("検出を開始しました")
            }
        }
    }

    func stop() {
        browser.stop()
        browsing = false
        note("検出を停止しました")
    }

    // MARK: 2. セッションとファイル

    func open(_ device: ICDevice) {
        guard let cam = device as? ICCameraDevice else {
            note("ICCameraDevice ではありません: \(type(of: device))", ok: false)
            return
        }
        camera = cam
        cam.delegate = self
        files = []
        note("セッションを開いています: \(cam.name ?? "?")")
        cam.requestOpenSession()
    }

    // MARK: 3. 生の PTP コマンド

    /// PTP の標準コンテナを組み立てる。
    ///   uint32 全長 / uint16 種別(1=Command) / uint16 オペコード
    ///   uint32 トランザクションID / uint32 パラメータ×N
    private func ptpCommand(code: UInt16, params: [UInt32] = []) -> Data {
        var d = Data()
        let length = UInt32(12 + params.count * 4)
        withUnsafeBytes(of: length.littleEndian) { d.append(contentsOf: $0) }
        withUnsafeBytes(of: UInt16(1).littleEndian) { d.append(contentsOf: $0) }
        withUnsafeBytes(of: code.littleEndian) { d.append(contentsOf: $0) }
        withUnsafeBytes(of: UInt32(1).littleEndian) { d.append(contentsOf: $0) }
        for p in params {
            withUnsafeBytes(of: p.littleEndian) { d.append(contentsOf: $0) }
        }
        return d
    }

    /// PTP の応答コードを読める名前にする
    private func responseName(_ code: UInt16) -> String {
        switch code {
        case 0x2001: return "OK"
        case 0x2002: return "GeneralError"
        case 0x2003: return "SessionNotOpen"
        case 0x2005: return "OperationNotSupported"
        case 0x2006: return "ParameterNotSupported"
        case 0x2009: return "InvalidObjectHandle"
        case 0x200A: return "DevicePropNotSupported"
        case 0x2013: return "NoValidObjectInfo"
        case 0x2019: return "DeviceBusy"
        case 0x201D: return "InvalidParameter"
        case 0x201E: return "SessionAlreadyOpen"
        // 以下は Nikon 独自
        case 0xA001: return "Nikon:HardwareError"
        case 0xA003: return "Nikon:ChangeCameraModeFailed"
        case 0xA004: return "Nikon:InvalidStatus"
        case 0xA005: return "Nikon:SetPropertyNotSupported"
        case 0xA009: return "Nikon:MirrorUpSequence"
        case 0xA00B: return "Nikon:NotLiveView"
        default:     return String(format: "0x%04x", code)
        }
    }

    /// 任意のオペコードを送る。応答コードとデータ長を記録する。
    func send(_ label: String, code: UInt16, params: [UInt32] = [], outData: Data? = nil,
              then next: (@MainActor (Bool) -> Void)? = nil) {
        guard let cam = camera else {
            note("先にカメラを開いてください", ok: false)
            return
        }
        let paramText = params.isEmpty ? "" : "  引数 " + params.map { String(format: "0x%08x", $0) }.joined(separator: ", ")
        note("送信 \(label) [\(String(format: "0x%04x", code))]\(paramText)")

        cam.requestSendPTPCommand(ptpCommand(code: code, params: params), outData: outData) { [weak self] data, resp, error in
            Task { @MainActor in
                guard let self else { return }
                if let error = error as NSError? {
                    let detail = error.code == -21249
                        ? "PTP コマンドが許可されていません (-21249)"
                        : "エラー \(error.code): \(error.localizedDescription)"
                    self.note("\(label): \(detail)", ok: false)
                    next?(false)
                    return
                }
                // 応答コンテナの 6〜7 バイト目が応答コード
                var rc: UInt16 = 0
                if resp.count >= 8 {
                    rc = UInt16(resp[6]) | (UInt16(resp[7]) << 8)
                }
                let ok = rc == 0x2001
                self.note("\(label): \(self.responseName(rc))  データ \(data.count) バイト", ok: ok)

                // JPEG なら中身を保持して画面に出す。
                // Nikon のライブビュー画像は独自ヘッダの後ろに JPEG が続くので、先頭から SOI を探す。
                if let jpeg = Self.jpeg(in: data) {
                    self.liveImage = UIImage(data: jpeg)
                    self.note("JPEG を受信（\(jpeg.count) バイト、先頭 \(data.count - jpeg.count) バイトはヘッダ）", ok: true)
                } else if data.count > 0, data.count <= 64 {
                    let hex = data.map { String(format: "%02x", $0) }.joined(separator: " ")
                    self.note("データ: \(hex)")
                }
                next?(ok)
            }
        }
    }

    /// GetDeviceInfo (0x1001)。副作用が無いので疎通確認に使う。
    func testPTP() {
        guard let cam = camera else {
            note("先にカメラを開いてください", ok: false)
            return
        }
        note("capabilities: \(cam.capabilities.map { "\($0)" }.joined(separator: ", "))")
        send("GetDeviceInfo", code: 0x1001)
    }

    // MARK: 実験用のコマンド群

    /// 標準の撮影命令。保存先とフォーマットは既定 (0, 0)。
    func remoteShutter()      { send("InitiateCapture", code: 0x100E, params: [0, 0]) }
    /// Nikon 独自の撮影命令。標準が効かない機種向け。
    func nikonCapture()       { send("Nikon Capture", code: 0x90C0, params: [0xFFFFFFFF]) }
    /// 絞り (FNumber)。値は 100 倍で返る。
    func readAperture()       { send("絞りを取得", code: 0x1015, params: [0x5007]) }
    /// ISO (ExposureIndex)
    func readISO()            { send("ISO を取得", code: 0x1015, params: [0x500F]) }
    /// バッテリー残量
    func readBattery()        { send("バッテリーを取得", code: 0x1015, params: [0x5001]) }
    /// 制御権をホストへ (1) / カメラへ返す (0)。Nikon ChangeCameraMode = 0x90C2。
    ///
    /// 以前はここで 0x9008 を送っていたが、Nikon の 0x9008 は DeleteProfile
    /// （無線 LAN プロファイルの削除）で、制御権とは無関係だった。
    /// 「iOS では制御権が握り潰される」という結論はこの取り違えによるもので、
    /// 正しい命令ではまだ検証していない。libgphoto2 の ptp.h / library.c と照合済み。
    func takeControl()        { send("制御権を取得", code: 0x90C2, params: [1]) }
    func releaseControl()     { send("制御権を返す", code: 0x90C2, params: [0]) }

    /// 背面液晶の撮影直後レビュー（再生メニューの「撮影直後の画像確認」）
    func readImageReview()    { send("撮影直後の画像確認を取得", code: 0x1015, params: [0xD165]) }
    /// 記録先。0 = カード、1 = SDRAM（カードに残らず、背面にも出ない）
    func readRecordingMedia() { send("記録先を取得", code: 0x1015, params: [0xD10B]) }
    func setRecordingMediaCard() {
        send("記録先をカードに", code: 0x1016, params: [0xD10B], outData: Data([0])) { [weak self] ok in
            guard ok else { return }
            self?.send("記録先を読み直す", code: 0x1015, params: [0xD10B])
        }
    }
    /// ライブビューを始められない理由のビット列。0 なら障害なし。
    func readLiveViewProhibit() { send("ライブビュー禁止条件を取得", code: 0x1015, params: [0xD1A4]) }

    /// libgphoto2 の Nikon ライブビュー開始手順をそのままなぞる（library.c）。
    ///   ChangeCameraMode(1) → RecordingMedia = SDRAM → StartLiveView → 画像取得
    /// ChangeCameraModeFailed (0xA003) は libgphoto2 も無視して先へ進むので、ここでも止めない。
    func liveViewSequence() {
        send("制御権を取得", code: 0x90C2, params: [1]) { [weak self] _ in
            guard let self else { return }
            self.send("記録先を SDRAM に", code: 0x1016, params: [0xD10B], outData: Data([1])) { _ in
                self.send("ライブビュー開始", code: 0x9201) { ok in
                    guard ok else {
                        self.readLiveViewProhibit()
                        self.note("開始できないので禁止条件を読んだ", ok: false)
                        return
                    }
                    // カメラがミラーアップを終えるまで少し待つ
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                        self.send("ライブビュー画像", code: 0x9203)
                    }
                }
            }
        }
    }

    /// ISO を 400 に設定して書き込みが効くか試す。
    /// PTP は値をリトルエンディアンの生バイトで渡す。400 = 0x0190。
    func writeISO400() {
        var v = UInt16(400).littleEndian
        let data = Data(bytes: &v, count: 2)
        send("ISO を 400 に設定", code: 0x1016, params: [0x500F], outData: data) { [weak self] ok in
            guard ok else { return }
            self?.send("ISO を読み直す", code: 0x1015, params: [0x500F])
        }
    }

    /// Nikon ライブビュー
    func liveViewStart()      { send("ライブビュー開始", code: 0x9201) }
    func liveViewGrab()       { send("ライブビュー画像", code: 0x9203) }
    func liveViewStop()       { send("ライブビュー終了", code: 0x9202) }

}

// MARK: - デバイス検出

extension CameraProbe: ICDeviceBrowserDelegate {
    nonisolated func deviceBrowser(_ browser: ICDeviceBrowser, didAdd device: ICDevice, moreComing: Bool) {
        Task { @MainActor in
            self.devices.append(device)
            self.note("検出: \(device.name ?? "名前なし")  種別=\(device.type.rawValue)", ok: true)
        }
    }

    nonisolated func deviceBrowser(_ browser: ICDeviceBrowser, didRemove device: ICDevice, moreGoing: Bool) {
        Task { @MainActor in
            self.devices.removeAll { $0 === device }
            self.note("取り外し: \(device.name ?? "名前なし")")
        }
    }
}

// MARK: - セッションとファイル列挙

extension CameraProbe: ICCameraDeviceDelegate {
    nonisolated func device(_ device: ICDevice, didOpenSessionWithError error: (any Error)?) {
        Task { @MainActor in
            if let error {
                self.note("セッションを開けません: \(error.localizedDescription)", ok: false)
            } else {
                self.openedName = device.name
                self.note("セッションを開きました", ok: true)
            }
        }
    }

    nonisolated func device(_ device: ICDevice, didCloseSessionWithError error: (any Error)?) {
        Task { @MainActor in self.note("セッションを閉じました") }
    }

    nonisolated func deviceDidBecomeReady(_ device: ICDevice) {
        let now = Date()
        Task { @MainActor in
            if let c = self.clock { c.ready = now.timeIntervalSince(c.t0) }
            self.note("デバイス準備完了")
        }
    }

    nonisolated func didRemove(_ device: ICDevice) {
        Task { @MainActor in self.note("デバイスが外れました") }
    }

    nonisolated func cameraDevice(_ camera: ICCameraDevice, didAdd items: [ICCameraItem]) {
        let now = Date()
        Task { @MainActor in
            let names = items.compactMap { $0.name }
            self.files.append(contentsOf: names)
            if let c = self.clock {
                // 計測中は 1 件ごとの記録を出さない（400 行になるため）
                if c.firstFile == nil { c.firstFile = now.timeIntervalSince(c.t0) }
                c.files += items.count
                if !c.baseline.isEmpty {
                    for n in names where !c.baseline.contains(n) {
                        c.newNames.append(n)
                        if c.firstNew == nil { c.firstNew = now.timeIntervalSince(c.t0) }
                    }
                }
                c.lastFile = now.timeIntervalSince(c.t0)
                return
            }
            self.note("ファイル \(items.count) 件を検出（累計 \(self.files.count)）", ok: true)
        }
    }

    nonisolated func cameraDevice(_ camera: ICCameraDevice, didRemove items: [ICCameraItem]) {}

    nonisolated func cameraDevice(_ camera: ICCameraDevice, didRenameItems items: [ICCameraItem]) {}

    nonisolated func cameraDeviceDidChangeCapability(_ camera: ICCameraDevice) {}

    nonisolated func cameraDevice(_ camera: ICCameraDevice,
                                  didReceiveThumbnail thumbnail: CGImage?,
                                  for item: ICCameraItem,
                                  error: (any Error)?) {}

    nonisolated func cameraDevice(_ camera: ICCameraDevice,
                                  didReceiveMetadata metadata: [AnyHashable: Any]?,
                                  for item: ICCameraItem,
                                  error: (any Error)?) {}

    /// カメラから届く PTP イベント。撮影完了などがここに来る。
    /// 生の PTP が通るなら、Mac 版と同じイベント駆動が iOS でも組める。
    nonisolated func cameraDevice(_ camera: ICCameraDevice, didReceivePTPEvent eventData: Data) {
        let hex = eventData.prefix(16).map { String(format: "%02x", $0) }.joined(separator: " ")
        Task { @MainActor in
            self.note("PTP イベント受信: \(eventData.count) バイト  \(hex)", ok: true)
        }
    }

    nonisolated func deviceDidBecomeReady(withCompleteContentCatalog device: ICCameraDevice) {
        let now = Date()
        Task { @MainActor in
            if let c = self.clock { c.complete = now.timeIntervalSince(c.t0) }
            self.note("カタログの読み込みが完了（ファイル \(self.files.count) 件）", ok: true)
        }
    }

    nonisolated func cameraDeviceDidEnableAccessRestriction(_ device: ICDevice) {}
    nonisolated func cameraDeviceDidRemoveAccessRestriction(_ device: ICDevice) {}
}


// MARK: - 制御権とライブビューの検証

extension CameraProbe {

    struct Reply { let ok: Bool; let code: UInt16; let data: Data }

    /// 記録を残さずに1往復する。検証の手順側で要点だけを書く。
    private func exchange(_ code: UInt16, _ params: [UInt32] = [], out: Data? = nil) async -> Reply {
        guard let cam = camera else { return Reply(ok: false, code: 0, data: Data()) }
        return await withCheckedContinuation { cont in
            cam.requestSendPTPCommand(ptpCommand(code: code, params: params), outData: out) { data, resp, error in
                if error != nil { cont.resume(returning: Reply(ok: false, code: 0, data: Data())); return }
                let rc: UInt16 = resp.count >= 8 ? UInt16(resp[6]) | (UInt16(resp[7]) << 8) : 0
                cont.resume(returning: Reply(ok: rc == 0x2001, code: rc, data: data))
            }
        }
    }

    private func hex(_ v: UInt16) -> String { String(format: "0x%04X", v) }

    /// 値の幅が機種で変わるので、返ったバイト数で読む
    private func readValue(_ prop: UInt16) async -> (reply: Reply, value: UInt32?) {
        let r = await exchange(0x1015, [UInt32(prop)])
        guard r.ok else { return (r, nil) }
        let b = [UInt8](r.data)
        switch b.count {
        case 1: return (r, UInt32(b[0]))
        case 2: return (r, UInt32(b[0]) | UInt32(b[1]) << 8)
        case 4: return (r, UInt32(b[0]) | UInt32(b[1]) << 8 | UInt32(b[2]) << 16 | UInt32(b[3]) << 24)
        default: return (r, nil)
        }
    }

    static func jpeg(in data: Data) -> Data? {
        let b = [UInt8](data.prefix(4096))
        guard b.count > 3 else { return nil }
        for i in 0..<(b.count - 2) where b[i] == 0xFF && b[i+1] == 0xD8 && b[i+2] == 0xFF {
            return data.subdata(in: (data.startIndex + i)..<data.endIndex)
        }
        return nil
    }

    /// PTP DeviceInfo から、対応オペコード・対応プロパティ・機種名を拾う
    private func parseDeviceInfo(_ data: Data) -> (ops: Set<UInt16>, props: Set<UInt16>, model: String, version: String)? {
        let b = [UInt8](data); var i = 0
        func u16() -> UInt16? { guard i + 2 <= b.count else { return nil }; defer { i += 2 }; return UInt16(b[i]) | UInt16(b[i+1]) << 8 }
        func u32() -> UInt32? { guard i + 4 <= b.count else { return nil }; defer { i += 4 }
            return UInt32(b[i]) | UInt32(b[i+1]) << 8 | UInt32(b[i+2]) << 16 | UInt32(b[i+3]) << 24 }
        func str() -> String? {
            guard i < b.count else { return nil }; let n = Int(b[i]); i += 1
            guard i + n * 2 <= b.count else { return nil }
            var units: [UInt16] = []
            for k in 0..<n { units.append(UInt16(b[i + 2*k]) | UInt16(b[i + 2*k + 1]) << 8) }
            i += n * 2
            return String(decoding: units.filter { $0 != 0 }, as: UTF16.self)
        }
        func arr16() -> Set<UInt16>? { guard let n = u32(), n < 4096 else { return nil }
            var out = Set<UInt16>(); for _ in 0..<n { guard let v = u16() else { return nil }; out.insert(v) }; return out }
        guard u16() != nil, u32() != nil, u16() != nil, str() != nil, u16() != nil,
              let ops = arr16(), arr16() != nil, let props = arr16(), arr16() != nil, arr16() != nil,
              str() != nil, let model = str(), let version = str() else { return nil }
        return (ops, props, model, version)
    }

    /// 以前 0x9008（Nikon では DeleteProfile）を送って出した結論を、正しい 0x90C2 でやり直す。
    /// 手順は libgphoto2 2.5.34 の library.c に合わせる。最後に必ず記録先をカードへ戻し、制御権を返す。
    func verifyControlAndLiveView() async {
        guard camera != nil else { note("先にカメラを開いてください", ok: false); return }
        note("===== 検証開始 =====")

        // 1. そもそも対応しているか
        let info = await exchange(0x1001)
        if info.ok, let di = parseDeviceInfo(info.data) {
            note("機種 \(di.model) / ファーム \(di.version) / 命令 \(di.ops.count) 種 / プロパティ \(di.props.count) 種")
            let ops: [(UInt16, String)] = [(0x90C2, "ChangeCameraMode"), (0x9201, "StartLiveView"),
                (0x9202, "EndLiveView"), (0x9203, "GetLiveViewImg"), (0x90C0, "CaptureRecInSdram"),
                (0x9207, "CaptureRecInMedia"), (0x90C7, "CheckEvent"), (0x90C8, "DeviceReady"), (0x9008, "DeleteProfile")]
            for (c, n) in ops { note("  命令 \(hex(c)) \(n): \(di.ops.contains(c) ? "対応" : "非対応")", ok: di.ops.contains(c)) }
            let props: [(UInt16, String)] = [(0xD165, "ImageReview"), (0xD10B, "RecordingMedia"),
                (0xD1A2, "LiveViewStatus"), (0xD1A4, "LiveViewProhibitCondition")]
            for (c, n) in props { note("  属性 \(hex(c)) \(n): \(di.props.contains(c) ? "一覧にあり" : "一覧になし（Nikon は別経路で持つことがある）")") }
        } else {
            note("DeviceInfo を読めない: \(responseName(info.code))", ok: false)
        }

        // 2. 現状の値
        let review = await readValue(0xD165)
        note("撮影直後の画像確認 0xD165 = \(review.value.map(String.init) ?? "読めず(\(responseName(review.reply.code)))")（0=オフ 1=オン）", ok: review.reply.ok)
        let media = await readValue(0xD10B)
        note("記録先 0xD10B = \(media.value.map(String.init) ?? "読めず(\(responseName(media.reply.code)))")（0=カード 1=SDRAM）", ok: media.reply.ok)
        if media.value == 1 { note("⚠️ 記録先が SDRAM になっている。この状態で撮るとカードに残らない", ok: false) }
        let lvs = await readValue(0xD1A2)
        note("ライブビュー状態 0xD1A2 = \(lvs.value.map(String.init) ?? "読めず")")
        let pro = await readValue(0xD1A4)
        note("ライブビュー禁止条件 0xD1A4 = \(pro.value.map { String(format: "0x%08X", $0) } ?? "読めず")（0 なら障害なし）")

        // 3. 制御権を取る
        let take = await exchange(0x90C2, [1])
        note("制御権を取得 0x90C2(1): \(responseName(take.code))", ok: take.ok || take.code == 0xA003)

        // 4. 記録先を SDRAM に（libgphoto2 と同じ）
        let sd = await exchange(0x1016, [0xD10B], out: Data([1]))
        note("記録先を SDRAM に: \(responseName(sd.code))", ok: sd.ok)

        // 5. ライブビュー
        let start = await exchange(0x9201)
        note("ライブビュー開始 0x9201: \(responseName(start.code))", ok: start.ok)
        if start.ok {
            // 準備完了を待つ（最大 3 秒）
            for _ in 0..<30 {
                if (await exchange(0x90C8)).ok { break }
                try? await Task.sleep(for: .milliseconds(100))
            }
            let began = Date(); var frames = 0; var bytes = 0
            for n in 0..<20 {
                let img = await exchange(0x9203)
                if img.ok, let jpeg = Self.jpeg(in: img.data), let ui = UIImage(data: jpeg) {
                    frames += 1; bytes += jpeg.count
                    liveImage = ui
                    if n == 0 {
                        note("1コマ目: \(Int(ui.size.width))×\(Int(ui.size.height)) / \(jpeg.count) バイト / ヘッダ \(img.data.count - jpeg.count) バイト", ok: true)
                        try? jpeg.write(to: Self.documents.appendingPathComponent("liveview.jpg"))
                    }
                } else if n == 0 {
                    note("画像取得 0x9203: \(responseName(img.code))  データ \(img.data.count) バイト", ok: false)
                }
            }
            let secs = Date().timeIntervalSince(began)
            note(String(format: "20回要求して %d コマ / %.1f 秒 → %.1f fps（平均 %d KB）",
                        frames, secs, Double(frames) / max(secs, 0.001), frames > 0 ? bytes / frames / 1024 : 0), ok: frames > 0)
            let end = await exchange(0x9202)
            note("ライブビュー終了 0x9202: \(responseName(end.code))", ok: end.ok)
        } else {
            let why = await readValue(0xD1A4)
            note("開始できなかった理由 0xD1A4 = \(why.value.map { String(format: "0x%08X", $0) } ?? "読めず")", ok: false)
        }

        // 6. 後始末。記録先はカードに、制御権はカメラに返す
        let back = await exchange(0x1016, [0xD10B], out: Data([0]))
        note("記録先をカードに戻す: \(responseName(back.code))", ok: back.ok)
        let give = await exchange(0x90C2, [0])
        note("制御権を返す 0x90C2(0): \(responseName(give.code))", ok: give.ok || give.code == 0xA003)
        let after = await readValue(0xD10B)
        note("後始末後の記録先 0xD10B = \(after.value.map(String.init) ?? "読めず")", ok: after.value == 0)

        note("===== 検証終了 =====")
        note("このままカメラ本体でシャッターを切って、背面液晶にレビューが出るか見てください")
    }
}


// MARK: - 接続速度の計測

/// 1 回の接続で、各段階に何秒かかったか
@MainActor
final class TrialClock {
    let label: String
    let t0 = Date()
    var opened: TimeInterval?
    var commandReturned: TimeInterval?
    var commandResult = ""
    var ready: TimeInterval?
    var firstFile: TimeInterval?
    var lastFile: TimeInterval?
    var complete: TimeInterval?
    var files = 0
    var percent: [(TimeInterval, Int)] = []
    /// 開く前から知っていたファイル名。これに無い名前が「閉じている間に増えた分」
    var baseline: Set<String> = []
    var newNames: [String] = []
    var firstNew: TimeInterval?
    init(label: String) { self.label = label }
    var elapsed: TimeInterval { Date().timeIntervalSince(t0) }
}

extension CameraProbe {

    private func fmt(_ t: TimeInterval?) -> String { t.map { String(format: "%6.1f秒", $0) } ?? "   ----" }

    private func closeSession(_ cam: ICCameraDevice) async {
        guard cam.hasOpenSession else { return }
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            cam.requestCloseSession(options: nil) { _ in cont.resume() }
        }
    }

    /// 開いてから全件の読み込みが終わるまでを 1 回計る
    private func trial(_ cam: ICCameraDevice, label: String, options: [ICSessionOptions: Any]?,
                       baseline: Set<String> = []) async -> TrialClock {
        let c = TrialClock(label: label)
        c.baseline = baseline
        clock = c
        files = []
        note("── \(label): セッションを開く")

        // 読み込み進捗の推移。準備完了より前に進むなら、その待ちの正体は列挙だと分かる
        let sampler = Task { @MainActor [weak c] in
            var last = -1
            while !Task.isCancelled, let c {
                let p = Int(cam.contentCatalogPercentCompleted)
                if p != last && (p / 10 != last / 10 || p == 100) { c.percent.append((c.elapsed, p)) }
                last = p
                try? await Task.sleep(for: .milliseconds(200))
            }
        }

        let openError: String? = await withCheckedContinuation { cont in
            cam.requestOpenSession(options: options) { error in cont.resume(returning: error?.localizedDescription) }
        }
        c.opened = c.elapsed
        if let openError { note("開けない: \(openError)", ok: false) }

        // 開いた直後に副作用のない命令を 1 つ送り、いつ返るかを見る
        let r = await exchange(0x1001)
        c.commandReturned = c.elapsed
        c.commandResult = r.ok ? "OK" : (r.code == 0 ? "エラー" : responseName(r.code))

        // 全件読み込みの完了を待つ（最大 3 分）
        for _ in 0..<900 {
            if c.complete != nil { break }
            try? await Task.sleep(for: .milliseconds(200))
        }
        sampler.cancel()
        clock = nil

        note(String(format: "   開いた %@ / 命令が返った %@ (%@) / 準備完了 %@ / 最初のファイル %@ / 読込完了 %@ / %d 件",
                    fmt(c.opened), fmt(c.commandReturned), c.commandResult, fmt(c.ready),
                    fmt(c.firstFile), fmt(c.complete), c.files), ok: c.complete != nil)
        let marks = c.percent.map { String(format: "%d%%@%.1f", $0.1, $0.0) }.joined(separator: " ")
        note("   進捗の推移: \(marks)")
        if !c.baseline.isEmpty {
            if c.newNames.isEmpty {
                note("   前回から増えたファイル: なし", ok: nil)
            } else {
                note("   前回から増えたファイル: \(c.newNames.count) 件 \(c.newNames.joined(separator: ", "))（最初の到着 \(fmt(c.firstNew))）", ok: true)
            }
        }
        return c
    }

    /// いま見えている中で一番新しいカメラ。抜き差し後は新しいオブジェクトになっているはず
    private var newestCamera: ICCameraDevice? {
        devices.compactMap { $0 as? ICCameraDevice }.last ?? camera
    }

    func closeCurrentSession() async {
        guard let cam = camera ?? newestCamera else { note("カメラがありません", ok: false); return }
        let count = files.count
        await closeSession(cam)
        openedName = nil
        note("セッションを閉じました（この時点のファイル \(count) 件）。カメラで撮ってから「1回だけ開いて計測」", ok: true)
    }

    /// 開いたままにする 1 回だけの計測。閉じている間の撮影、抜き差し、強制終了の後に使う
    func measureOnce() async {
        guard let cam = newestCamera else { note("先に「検出を開始」してください", ok: false); return }
        measuring = true
        defer { measuring = false }
        let same = lastMeasured.map { $0 === cam } ?? false
        note("===== 1回だけ開いて計測 =====")
        note("   カメラ: \(cam.name ?? "?") / UUID \(cam.uuidString ?? "?") / 前回と\(lastMeasured == nil ? "比較なし（このプロセスで初回）" : same ? "同じオブジェクト" : "別のオブジェクト")")
        let baseline = Set(files)
        camera = cam
        cam.delegate = self
        if cam.hasOpenSession {
            note("   開いているので一度閉じます")
            await closeSession(cam)
            try? await Task.sleep(for: .seconds(2))
        }
        _ = await trial(cam, label: "1回計測", options: nil, baseline: baseline)
        lastMeasured = cam
        openedName = cam.name
        note("===== 計測終了（セッションは開いたまま） =====")
    }

    /// 同じカメラにつなぎ直しを繰り返し、待ちが初回だけか、指定で変わるかを見る
    func measureConnections() async {
        guard let cam = camera ?? devices.compactMap({ $0 as? ICCameraDevice }).first else {
            note("先に「検出を開始」してカメラを見つけてください", ok: false); return
        }
        measuring = true
        defer { measuring = false }
        camera = cam
        cam.delegate = self
        note("===== 接続速度の計測開始 =====")
        if cam.hasOpenSession {
            note("開いているセッションを閉じてから始めます")
            await closeSession(cam)
            try? await Task.sleep(for: .seconds(3))
        }

        let chrono: [ICSessionOptions: Any] = [.enumerationChronologicalOrder: true]
        let plan: [(String, [ICSessionOptions: Any]?)] = [
            ("標準 1回目", nil), ("標準 2回目", nil), ("標準 3回目", nil),
            ("時系列順 1回目", chrono), ("時系列順 2回目", chrono),
        ]
        var results: [TrialClock] = []
        for (label, options) in plan {
            results.append(await trial(cam, label: label, options: options))
            await closeSession(cam)
            try? await Task.sleep(for: .seconds(3))
        }

        note("===== まとめ =====")
        note("試行           開く    命令    準備完了  最初    完了    件数")
        for c in results {
            let name = c.label.padding(toLength: 10, withPad: "　", startingAt: 0)
            note("\(name) \(fmt(c.opened)) \(fmt(c.commandReturned)) \(fmt(c.ready)) \(fmt(c.firstFile)) \(fmt(c.complete))  \(c.files)")
        }
        note("===== 接続速度の計測終了 =====")
        openedName = nil
    }
}
