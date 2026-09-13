import Foundation

/// PTP (Picture Transfer Protocol) の最小限の実装。
///
/// ImageCaptureCore は撮影や設定変更の高レベル API を iOS に提供していないが、
/// requestSendPTPCommand で生のオペコードは通る。そこでコマンドの組み立てと
/// 応答の解釈を自前で持つ。
enum PTP {

    // MARK: オペコード

    enum Op: UInt16 {
        case getDeviceInfo        = 0x1001
        case getStorageIDs        = 0x1004
        case getObjectHandles     = 0x1007
        case getObjectInfo        = 0x1008
        case getObject            = 0x1009
        case getThumb             = 0x100A
        case initiateCapture      = 0x100E
        case getDevicePropDesc    = 0x1014
        case getDevicePropValue   = 0x1015
        case setDevicePropValue   = 0x1016
        case nikonCapture         = 0x90C0
        case nikonAfDrive         = 0x90C1
        case nikonCheckEvent      = 0x90C7
        case nikonDeviceReady     = 0x90C8
        /// Nikon 独自プロパティの一覧。D300 は DeviceInfo に標準の分しか載せない
        case nikonGetVendorPropCodes = 0x90CA
        /// 制御権。0x9008 ではない（Nikon の 0x9008 は DeleteProfile）。libgphoto2 ptp.h で確認
        case nikonChangeCameraMode = 0x90C2
        case nikonStartLiveView   = 0x9201
        case nikonEndLiveView     = 0x9202
        case nikonGetLiveViewImg  = 0x9203
    }

    // MARK: プロパティコード

    enum Prop: UInt16, CaseIterable {
        case batteryLevel     = 0x5001
        case imageSize        = 0x5003
        case whiteBalance     = 0x5005
        case fNumber          = 0x5007
        case exposureTime     = 0x500D
        case exposureProgram  = 0x500E
        case iso              = 0x500F
        case exposureBias     = 0x5010
        /// Nikon 独自のシャッタースピード。上位 16 ビットが分子、下位 16 ビットが分母の正確な分数。
        /// 標準の 0x500D は 0.1 ミリ秒の整数に丸めるため、D300 では 1/8000 が 1、1/3200 が 3 になり
        /// 「1/10000」「1/3333」と表示されていた（実機の選択肢で確認）。Nikon ではこちらを使う
        case nikonExposureTime = 0xD100

        var label: String {
            switch self {
            case .batteryLevel:    return String(localized: "バッテリー")
            case .imageSize:       return String(localized: "画像サイズ")
            case .whiteBalance:    return String(localized: "WB")
            case .fNumber:         return String(localized: "絞り")
            case .exposureTime, .nikonExposureTime: return String(localized: "シャッター")
            case .exposureProgram: return String(localized: "モード")
            case .iso:             return "ISO"
            case .exposureBias:    return String(localized: "露出補正")
            }
        }
    }

    // MARK: データ型

    enum DataType: UInt16 {
        case int8 = 0x0001, uint8 = 0x0002
        case int16 = 0x0003, uint16 = 0x0004
        case int32 = 0x0005, uint32 = 0x0006
        case int64 = 0x0007, uint64 = 0x0008
        case string = 0xFFFF

        var byteCount: Int {
            switch self {
            case .int8, .uint8:   return 1
            case .int16, .uint16: return 2
            case .int32, .uint32: return 4
            case .int64, .uint64: return 8
            case .string:         return 0   // 可変長
            }
        }
    }

    // MARK: コマンドの組み立て

    /// PTP の標準コンテナ。
    ///   uint32 全長 / uint16 種別(1=Command) / uint16 オペコード
    ///   uint32 トランザクションID / uint32 パラメータ×N
    /// トランザクションIDは ImageCaptureCore が振り直すので 1 固定でよい。
    static func command(_ op: Op, _ params: UInt32...) -> Data {
        command(op, params: params)
    }

    static func command(_ op: Op, params: [UInt32]) -> Data {
        var d = Data()
        let length = UInt32(12 + params.count * 4)
        d.appendLE(length)
        d.appendLE(UInt16(1))
        d.appendLE(op.rawValue)
        d.appendLE(UInt32(1))
        for p in params { d.appendLE(p) }
        return d
    }

    /// カメラの内蔵時計。PTP では文字列型で持つ。
    static let dateTimeProp: UInt32 = 0x5011

    /// PTP 文字列: uint8 文字数（終端含む）→ UTF-16LE
    static func decodeString(_ data: Data) -> String? {
        guard let count = data.first, count > 1 else { return nil }
        let bytes = data.dropFirst()
        let units = stride(from: 0, to: min(Int(count - 1) * 2, bytes.count - 1), by: 2).map { i -> UInt16 in
            let idx = bytes.startIndex + i
            return UInt16(bytes[idx]) | (UInt16(bytes[idx + 1]) << 8)
        }
        return String(decoding: units, as: UTF16.self)
    }

    static func encodeString(_ value: String) -> Data {
        let units = Array(value.utf16) + [0]
        var d = Data()
        d.append(UInt8(units.count))
        for u in units { d.appendLE(u) }
        return d
    }

    /// 応答コンテナからコードを取り出す
    static func responseCode(_ data: Data) -> UInt16 {
        guard data.count >= 8 else { return 0 }
        return UInt16(data[data.startIndex + 6]) | (UInt16(data[data.startIndex + 7]) << 8)
    }

    static func isOK(_ data: Data) -> Bool { responseCode(data) == 0x2001 }

    static func responseName(_ code: UInt16) -> String {
        switch code {
        case 0x2001: return "OK"
        case 0x2002: return "GeneralError"
        case 0x2003: return "SessionNotOpen"
        case 0x2005: return "OperationNotSupported"
        case 0x2006: return "ParameterNotSupported"
        case 0x200A: return "DevicePropNotSupported"
        case 0x2019: return "DeviceBusy"
        case 0x201D: return "InvalidParameter"
        case 0xA002: return String(localized: "ピントが合いませんでした")
        case 0xA003: return "Nikon:ChangeCameraModeFailed"
        case 0xA004: return "Nikon:InvalidStatus"
        case 0xA005: return "Nikon:SetPropertyNotSupported"
        case 0xA00B: return "Nikon:NotLiveView"
        case 0x0000: return String(localized: "応答なし")
        default:     return String(format: "0x%04x", code)
        }
    }
}

// MARK: - バイト列の読み書き

extension Data {
    mutating func appendLE<T: FixedWidthInteger>(_ value: T) {
        var v = value.littleEndian
        // Data の拡張内なので、明示しないと Data 自身のメソッドと衝突する
        Swift.withUnsafeBytes(of: &v) { append(contentsOf: $0) }
    }
}

/// リトルエンディアンの連続読み出し。PTP のデータセットは全てこの形式。
struct PTPReader {
    let data: Data
    private(set) var offset: Int

    init(_ data: Data) {
        self.data = data
        self.offset = data.startIndex
    }

    var remaining: Int { data.endIndex - offset }

    mutating func read<T: FixedWidthInteger>(_ type: T.Type) -> T? {
        let size = MemoryLayout<T>.size
        guard remaining >= size else { return nil }
        var value: T = 0
        withUnsafeMutableBytes(of: &value) { dst in
            data.copyBytes(to: dst, from: offset..<(offset + size))
        }
        offset += size
        return T(littleEndian: value)
    }

    /// 型に応じた 1 値を Int64 に正規化して返す
    mutating func readValue(as type: PTP.DataType) -> Int64? {
        switch type {
        case .int8:   return read(Int8.self).map(Int64.init)
        case .uint8:  return read(UInt8.self).map(Int64.init)
        case .int16:  return read(Int16.self).map(Int64.init)
        case .uint16: return read(UInt16.self).map(Int64.init)
        case .int32:  return read(Int32.self).map(Int64.init)
        case .uint32: return read(UInt32.self).map(Int64.init)
        case .int64:  return read(Int64.self)
        case .uint64: return read(UInt64.self).map { Int64(bitPattern: $0) }
        case .string:
            // PTP 文字列: 先頭に文字数、以降 UTF-16LE
            guard let count = read(UInt8.self) else { return nil }
            offset += Int(count) * 2
            return 0
        }
    }
}
