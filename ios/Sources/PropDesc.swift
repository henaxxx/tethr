import Foundation

/// GetDevicePropDesc (0x1014) が返すデータセットの解析結果。
///
/// カメラは「現在値」だけでなく「取り得る値の一覧」も返してくる。
/// スクラバーの選択肢はここから作る。決め打ちの表を持つ必要はない。
struct PropDesc {
    let code: PTP.Prop
    let dataType: PTP.DataType
    let writable: Bool
    let current: Int64
    /// 選択肢。列挙形式のときだけ埋まる。
    let choices: [Int64]

    /// データセットの構造は PTP 仕様で決まっている。
    ///   uint16 プロパティコード / uint16 データ型 / uint8 読み書き可否
    ///   既定値 / 現在値 / uint8 フォーム種別
    ///   フォーム 1 = 範囲（最小・最大・刻み） / 2 = 列挙（個数 + 値の並び）
    init?(_ data: Data) {
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

    var currentText: String { PropFormat.text(code, current) }
    var choiceTexts: [String] { choices.map { PropFormat.text(code, $0) } }
}

/// PTP の生の数値を人間が読む形にする。
/// 単位は仕様で決まっていて、機種によらず共通。
enum PropFormat {

    static func text(_ prop: PTP.Prop, _ value: Int64) -> String {
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

        case .iso:
            return "\(value)"

        case .exposureBias:
            // 0.001 EV 単位
            let ev = Double(value) / 1000
            if abs(ev) < 0.01 { return "±0" }
            return String(format: "%@%.1fEV", ev > 0 ? "+" : "−", abs(ev))

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
            // PTP 仕様で定義されている値。機種を問わず共通。
            switch value {
            case 1: return String(localized: "マニュアル")
            case 2: return String(localized: "オート")
            case 3: return String(localized: "ワンタッチ")
            case 4: return String(localized: "晴天")
            case 5: return String(localized: "蛍光灯")
            case 6: return String(localized: "電球")
            case 7: return String(localized: "フラッシュ")
            default:
                // メーカー独自の値。推測で名前を付けず、コードのまま出す。
                return String(format: "0x%04X", UInt16(truncatingIfNeeded: value))
            }

        case .imageSize:
            return "\(value)"
        }
    }
}
