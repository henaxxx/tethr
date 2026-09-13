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

    override init() {
        super.init()
        browser.delegate = self
    }

    private func note(_ text: String, ok: Bool? = nil) {
        findings.insert(Finding(text: text, ok: ok), at: 0)
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

                // JPEG なら中身を保持して画面に出す
                if data.count > 4, data[0] == 0xFF, data[1] == 0xD8 {
                    self.liveImage = UIImage(data: data)
                    self.note("JPEG を受信（\(data.count) バイト）", ok: true)
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
        Task { @MainActor in self.note("デバイス準備完了") }
    }

    nonisolated func didRemove(_ device: ICDevice) {
        Task { @MainActor in self.note("デバイスが外れました") }
    }

    nonisolated func cameraDevice(_ camera: ICCameraDevice, didAdd items: [ICCameraItem]) {
        Task { @MainActor in
            let names = items.compactMap { $0.name }
            self.files.append(contentsOf: names)
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
        Task { @MainActor in
            self.note("カタログの読み込みが完了（ファイル \(self.files.count) 件）", ok: true)
        }
    }

    nonisolated func cameraDeviceDidEnableAccessRestriction(_ device: ICDevice) {}
    nonisolated func cameraDeviceDidRemoveAccessRestriction(_ device: ICDevice) {}
}
