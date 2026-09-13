import Foundation

/// カメラが返す文字列を人間が読む形に整える。
/// libgphoto2 の値は機種やウィジェットによって表記が揺れる
/// （"0.1666s" だったり "1/6" だったり "22" だったり）ため、
/// 表示側で一度正規化してから使う。
enum Format {

    /// "0.1666s" → "1/6" / "2.5s" → "2.5\"" / "Bulb" → "Bulb"
    static func shutter(_ raw: String) -> String {
        let trimmed = raw.hasSuffix("s") ? String(raw.dropLast()) : raw
        guard let v = Double(trimmed), v > 0 else { return raw }
        if v >= 1 {
            let s = v.rounded() == v ? String(Int(v)) : String(format: "%.1f", v)
            return "\(s)\""
        }
        // 分母が整数でない段がある（1/2.5・1/1.6・1/1.3）。四捨五入すると 1/3・1/2・1/1 になり、
        // 隣の段と表示が重なる。整数に近いときだけ整数で出す
        let denominator = 1 / v
        let nearest = denominator.rounded()
        if abs(denominator - nearest) / denominator < 0.02 {
            return "1/\(Int(nearest))"
        }
        return String(format: "1/%.1f", denominator)
    }

    /// "22" → "f/22" / "f/5.6" → "f/5.6"
    static func aperture(_ raw: String) -> String {
        if raw.lowercased().hasPrefix("f/") { return raw }
        guard let v = Double(raw) else { return raw }
        let s = v.rounded() == v ? String(Int(v)) : String(format: "%.1f", v)
        return "f/\(s)"
    }

    /// "320" → "320"（そのまま。Auto などの文字列も通す）
    static func iso(_ raw: String) -> String { raw }

    /// "18 mm" / "18" → "18mm"
    static func focal(_ raw: String) -> String {
        let n = raw.replacingOccurrences(of: " ", with: "")
        if n.hasSuffix("mm") { return n }
        guard let v = Double(n) else { return raw }
        return "\(Int(v))mm"
    }

    /// "18 mm" → 18
    static func number(_ raw: String?) -> Double? {
        guard let raw else { return nil }
        let cleaned = raw.replacingOccurrences(of: "[^0-9.\\-]", with: "", options: .regularExpression)
        return Double(cleaned)
    }

    /// 露出補正 "-0.333" → "−0.3EV"
    static func exposureCompensation(_ raw: String) -> String {
        guard let v = Double(raw) else { return raw }
        if abs(v) < 0.01 { return "±0" }
        return String(format: "%@%.1fEV", v > 0 ? "+" : "−", abs(v))
    }
}
