#if DEBUG
import CoreGraphics
import Foundation

/// デモ用の写真。空と山と太陽だけの、色の違う風景（iOS と Mac のデモで共通）。
/// 製品版には含めない
public enum DemoLandscape {

    /// seed で色と山の形が決まる。sunShift（0〜1）で太陽が横に動く（ライブビューのデモ用）
    public static func make(seed: Int, portrait: Bool, sunShift: Double = 0, scale: CGFloat = 1) -> CGImage? {
        let w = (portrait ? 800 : 1200) * scale
        let h = (portrait ? 1200 : 800) * scale
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let cg = CGContext(data: nil, width: Int(w), height: Int(h), bitsPerComponent: 8, bytesPerRow: 0,
                                 space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        // UIKit と同じく左上を原点にする
        cg.translateBy(x: 0, y: h)
        cg.scaleBy(x: 1, y: -1)

        let hue = CGFloat((seed * 37) % 100) / 100
        let sky = [color(hue, 0.45, 0.95), color((hue + 0.08).truncatingRemainder(dividingBy: 1), 0.55, 0.55)]
        if let gradient = CGGradient(colorsSpace: space, colors: sky as CFArray, locations: [0, 1]) {
            cg.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: 0, y: h), options: [])
        }

        cg.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.85))
        let sun = w * 0.09
        let sunX = (0.2 + 0.5 * CGFloat(seed % 3) / 3 + 0.3 * CGFloat(sunShift)).truncatingRemainder(dividingBy: 0.9)
        cg.fillEllipse(in: CGRect(x: w * sunX, y: h * 0.2, width: sun, height: sun))

        for layer in 0..<3 {
            let base = h * (0.55 + CGFloat(layer) * 0.12)
            let path = CGMutablePath()
            path.move(to: CGPoint(x: 0, y: h))
            path.addLine(to: CGPoint(x: 0, y: base))
            let peaks = 4 + (seed + layer) % 3
            for p in 0...peaks {
                let x = w * CGFloat(p) / CGFloat(peaks)
                let lift = CGFloat(((seed + 3) * (p + 7) * (layer + 5)) % 23) / 23 * h * 0.14
                path.addLine(to: CGPoint(x: x, y: base - lift))
            }
            path.addLine(to: CGPoint(x: w, y: h))
            path.closeSubpath()
            cg.addPath(path)
            cg.setFillColor(color((hue + 0.5).truncatingRemainder(dividingBy: 1), 0.35, 0.42 - CGFloat(layer) * 0.12))
            cg.fillPath()
        }
        return cg.makeImage()
    }

    /// UIColor(hue:saturation:brightness:) と同じ HSB から sRGB への変換
    private static func color(_ h: CGFloat, _ s: CGFloat, _ v: CGFloat) -> CGColor {
        let i = floor(h * 6)
        let f = h * 6 - i
        let p = v * (1 - s), q = v * (1 - f * s), t = v * (1 - (1 - f) * s)
        let (r, g, b): (CGFloat, CGFloat, CGFloat)
        switch Int(i) % 6 {
        case 0: (r, g, b) = (v, t, p)
        case 1: (r, g, b) = (q, v, p)
        case 2: (r, g, b) = (p, v, t)
        case 3: (r, g, b) = (p, q, v)
        case 4: (r, g, b) = (t, p, v)
        default: (r, g, b) = (v, p, q)
        }
        return CGColor(srgbRed: r, green: g, blue: b, alpha: 1)
    }
}
#endif
