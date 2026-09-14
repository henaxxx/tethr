import Foundation

/// PTP の DeviceInfo（GetDeviceInfo 0x1001 の返り値）。
///
///   uint16 規格版 / uint32 VendorExtensionID / uint16 拡張版 / 文字列 拡張説明 / uint16 機能モード /
///   配列×5（命令・イベント・属性・撮影形式・画像形式）/ 文字列 メーカー名 / 機種名 / ファームウェア版 / シリアル番号
public struct DeviceInfo {
    public let vendor: UInt32
    public let manufacturer: String
    public let model: String
    public let version: String
    public let serialNumber: String
    public let operations: [UInt16]
    public let events: [UInt16]
    public let properties: [UInt16]

    public init?(_ data: Data) {
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
        self.vendor = vendor
        self.manufacturer = manufacturer
        self.model = string() ?? ""
        self.version = string() ?? ""
        self.serialNumber = string() ?? ""
        self.operations = operations
        self.events = events
        self.properties = properties
    }

    /// 独自の値の読み方を決めるメーカー番号。
    ///
    /// D300 は VendorExtensionID に Microsoft（0x6 = MTP）を名乗る。
    /// libgphoto2 も同じ補正をしている（library.c: Manufacturer に "Nikon" があれば Nikon とみなす）
    public var effectiveVendor: UInt32 {
        guard vendor == 0x6 || vendor == 0xFFFF_FFFF || vendor == 0 else { return vendor }
        if manufacturer.localizedCaseInsensitiveContains("Nikon") { return PropFormat.vendorNikon }
        if manufacturer.localizedCaseInsensitiveContains("Sony") { return PropFormat.vendorSony }
        return vendor
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
public struct CameraCapabilities {
    public let model: String
    public let operations: Set<UInt16>
    public let events: Set<UInt16>
    public let properties: Set<UInt16>
    /// libgphoto2 と同じ判定: Nikon で、機種名が J・V で始まるか S1・S2
    public let isNikon1: Bool

    private static let nikon1Unsafe: Set<UInt16> = [0x90C2, 0x90C7, 0x90CA, 0x90C0]

    public init(_ info: DeviceInfo) {
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
    public static func refusalBeforeDeviceInfo(_ op: PTP.Op, params: [UInt32]) -> (reason: String, code: UInt16)? {
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
    public func refusal(_ op: PTP.Op, params: [UInt32]) -> (reason: String, code: UInt16)? {
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
