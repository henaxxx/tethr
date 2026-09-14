import Foundation

/// GetDevicePropDesc (0x1014) が返すデータセットの解析結果。
///
/// カメラは「現在値」だけでなく「取り得る値の一覧」も返してくる。
/// スクラバーの選択肢はここから作る。決め打ちの表を持つ必要はない。
public struct PropDesc {
    public let code: PTP.Prop
    public let dataType: PTP.DataType
    public let writable: Bool
    public let current: Int64
    /// 選択肢。列挙形式のときだけ埋まる。
    public let choices: [Int64]

    /// データセットの構造は PTP 仕様で決まっている。
    ///   uint16 プロパティコード / uint16 データ型 / uint8 読み書き可否
    ///   既定値 / 現在値 / uint8 フォーム種別
    ///   フォーム 1 = 範囲（最小・最大・刻み） / 2 = 列挙（個数 + 値の並び）
    public init?(_ data: Data) {
        var r = PTPReader(data)
        guard let rawCode = r.read(UInt16.self),
              let code = PTP.Prop(rawValue: rawCode),
              let rawType = r.read(UInt16.self),
              let type = PTP.DataType(rawValue: rawType),
              let getSet = r.read(UInt8.self),
              r.readValue(as: type) != nil,               // 既定値は使わないが読み飛ばす
              let current = r.readValue(as: type),
              let form = r.read(UInt8.self)
        else { return nil }

        self.code = code
        self.dataType = type
        self.writable = getSet == 1
        self.current = current

        switch form {
        case 2:
            guard let count = r.read(UInt16.self) else { self.choices = []; return }
            var values: [Int64] = []
            values.reserveCapacity(Int(count))
            for _ in 0..<count {
                guard let v = r.readValue(as: type) else { break }
                values.append(v)
            }
            self.choices = values
        case 1:
            // 範囲形式。刻みが細かいと選択肢が膨大になるので、
            // 現実的な件数に収まるときだけ展開する。
            guard let lo = r.readValue(as: type),
                  let hi = r.readValue(as: type),
                  let step = r.readValue(as: type), step > 0,
                  (hi - lo) / step < 512
            else { self.choices = []; return }
            var values: [Int64] = []
            var v = lo
            while v <= hi {
                values.append(v)
                v += step
            }
            self.choices = values
        default:
            self.choices = []
        }
    }

    /// カメラ無しで組み立てる（画面の確認用のデモなど）
    public init(code: PTP.Prop, dataType: PTP.DataType, writable: Bool, current: Int64, choices: [Int64]) {
        self.code = code
        self.dataType = dataType
        self.writable = writable
        self.current = current
        self.choices = choices
    }

    public var currentText: String { PropFormat.text(code, current) }
    public var choiceTexts: [String] { choices.map { PropFormat.text(code, $0) } }
}

/// PTP の生の数値を人間が読む形にする。
/// 単位は仕様で決まっていて、機種によらず共通。
public enum PropFormat {

    public static func text(_ prop: PTP.Prop, _ value: Int64) -> String {
        switch prop {
        case .fNumber:
            // 絞りは 100 倍の整数。560 → f/5.6
            let f = Double(value) / 100
            return f == f.rounded() ? "f/\(Int(f))" : String(format: "f/%.1f", f)

        case .exposureTime:
            // 0.1ms 単位。40 → 1/250 秒
            if value == 0xFFFFFFFF { return "Bulb" }
            if value == 0xFFFFFFFE { return "Time" }
            guard value > 0 else { return "—" }
            let seconds = Double(value) / 10_000
            if seconds >= 1 {
                return seconds == seconds.rounded()
                    ? "\(Int(seconds))\""
                    : String(format: "%.1f\"", seconds)
            }
            // 分母が整数でない段がある（1/2.5・1/1.6・1/1.3）。四捨五入すると 1/3・1/2・1/1 になり、
            // 隣の段と表示が重なる。整数に近いときだけ整数で出す
            let denominator = 1 / seconds
            let nearest = denominator.rounded()
            if abs(denominator - nearest) / denominator < 0.02 {
                return "1/\(Int(nearest))"
            }
            return String(format: "1/%.1f", denominator)

        case .nikonExposureTime:
            // libgphoto2 の _get_Nikon_ShutterSpeed と同じ読み方
            switch UInt32(truncatingIfNeeded: value) {
            case 0xFFFF_FFFF: return "Bulb"
            case 0xFFFF_FFFE: return "x200"
            case 0xFFFF_FFFD: return "Time"
            default: break
            }
            let raw = UInt32(truncatingIfNeeded: value)
            let numerator = Double(raw >> 16)
            let denominator = Double(raw & 0xFFFF)
            guard numerator > 0, denominator > 0 else { return "—" }
            let seconds = numerator / denominator
            if seconds >= 1 {
                return seconds == seconds.rounded() ? "\(Int(seconds))\"" : String(format: "%.1f\"", seconds)
            }
            // 10/25 のような表し方もあるので、秒に直してから 1/x の形にそろえる
            let reciprocal = denominator / numerator
            return reciprocal == reciprocal.rounded() ? "1/\(Int(reciprocal))" : String(format: "1/%.1f", reciprocal)

        case .iso:
            return "\(value)"

        case .exposureBias:
            // 0.001 EV 単位。スクラバーの 1 段に収まるよう単位は付けない（名前の「露出補正」で分かる）
            let ev = Double(value) / 1000
            if abs(ev) < 0.01 { return "±0" }
            return String(format: "%@%.1f", ev > 0 ? "+" : "−", abs(ev))

        case .batteryLevel:
            return "\(value)%"

        case .exposureProgram:
            switch value {
            case 1: return "M"
            case 2: return "P"
            case 3: return "A"
            case 4: return "S"
            default: return "\(value)"
            }

        case .whiteBalance:
            switch value {
            // PTP 仕様で定義されている値。機種を問わず共通。
            case 1: return String(localized: "マニュアル")
            case 2: return String(localized: "オート")
            case 3: return String(localized: "ワンタッチ")
            case 4: return String(localized: "晴天")
            case 5: return String(localized: "蛍光灯")
            case 6: return String(localized: "電球")
            case 7: return String(localized: "フラッシュ")
            default:
                // 0x8000 以降はメーカー独自。同じ番号でもメーカーで意味が違う（富士は 0x8001〜 が蛍光灯の種類）ので、
                // libgphoto2 の表（config.c の whitebalance[]）で確かめたものだけ名前を付ける
                if let name = vendorWhiteBalanceName(value) { return name }
                return String(format: "0x%04X", UInt16(truncatingIfNeeded: value))
            }

        case .imageSize:
            return "\(value)"

        case .compressionSetting:
            // Nikon の並び（libgphoto2 の compressionsetting 表と同じ）。D300 は 8 通り
            switch (vendor, value) {
            case (vendorNikon, 0): return "JPEG Basic"
            case (vendorNikon, 1): return "JPEG Normal"
            case (vendorNikon, 2): return "JPEG Fine"
            case (vendorNikon, 3): return "TIFF (RGB)"
            case (vendorNikon, 4): return "NEF (RAW)"
            case (vendorNikon, 5): return "NEF + Basic"
            case (vendorNikon, 6): return "NEF + Normal"
            case (vendorNikon, 7): return "NEF + Fine"
            default: return "\(value)"
            }

        case .focalLength:
            let mm = Double(value) / 100
            return mm == mm.rounded() ? "\(Int(mm))mm" : String(format: "%.1fmm", mm)

        case .focusMode:
            switch value {
            case 1: return "MF"
            case 2: return "AF"
            case 3: return String(localized: "マクロ")
            case 0x8010 where vendor == vendorNikon: return "AF-S"
            case 0x8011 where vendor == vendorNikon: return "AF-C"
            case 0x8012 where vendor == vendorNikon: return "AF-A"
            default: return String(format: "0x%04X", UInt16(truncatingIfNeeded: value))
            }
        }
    }

    /// つないでいるカメラのメーカー（DeviceInfo の VendorExtensionID）。独自の値の読み方を決める
    public static var vendor: UInt32 = 0
    public static let vendorNikon: UInt32 = 0x0A
    public static let vendorSony: UInt32 = 0x11

    private static func vendorWhiteBalanceName(_ value: Int64) -> String? {
        switch (vendor, value) {
        case (vendorNikon, 0x8010), (vendorSony, 0x8010): return String(localized: "曇天")
        case (vendorNikon, 0x8011), (vendorSony, 0x8011): return String(localized: "日陰")
        case (vendorNikon, 0x8012), (vendorSony, 0x8012): return String(localized: "色温度")
        case (vendorNikon, 0x8013):                       return String(localized: "プリセット")
        case (vendorNikon, 0x8014):                       return String(localized: "オフ")
        case (vendorNikon, 0x8016):                       return String(localized: "自然光オート")
        default: return nil
        }
    }

    /// 白バランスのアイコン。ボタンにはこれだけを出す
    public static func whiteBalanceSymbol(_ value: Int64) -> String {
        switch value {
        case 1: return "slider.horizontal.3"
        case 2: return "a.circle"
        case 3: return "hand.tap"
        case 4: return "sun.max"
        case 5: return "light.cylindrical.ceiling"
        case 6: return "lightbulb"
        case 7: return "bolt"
        default:
            guard vendorWhiteBalanceName(value) != nil else { return "circle.lefthalf.filled" }
            switch value {
            case 0x8010: return "cloud"
            case 0x8011: return "house"              // Nikon の表示でも日陰は家の絵
            case 0x8012: return "thermometer.medium"
            case 0x8013: return "eyedropper"
            case 0x8014: return "circle.slash"
            case 0x8016: return "sun.haze"
            default:     return "circle.lefthalf.filled"
            }
        }
    }
}
