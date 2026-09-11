// アプリアイコンを描いて icon_1024.png を出力する。
// 絞り羽根をモチーフにした理由: 16px まで縮んでも輪郭が残り、
// カメラ関連だと一目で分かるため。
import AppKit
import CoreGraphics
import Foundation

// iOS は角丸をシステム側が付けるため、正方形いっぱいに描く。
// macOS は自分で角丸を描く必要がある（グリッドに合わせて余白も取る）。
let forIOS = CommandLine.arguments.contains("--ios")
let side = 1024
let cs = CGColorSpaceCreateDeviceRGB()
guard let ctx = CGContext(data: nil, width: side, height: side,
                          bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
    fatalError("コンテキストを作れません")
}

let s = CGFloat(side)
func rgb(_ r: Int, _ g: Int, _ b: Int, _ a: CGFloat = 1) -> CGColor {
    CGColor(red: CGFloat(r)/255, green: CGFloat(g)/255, blue: CGFloat(b)/255, alpha: a)
}

// --- 角丸の下地。macOS のアイコングリッドに合わせて 1024 中 824 を使う ---
let inset: CGFloat = forIOS ? 0 : 100
let rect = CGRect(x: inset, y: inset, width: s - inset*2, height: s - inset*2)
let squircle = forIOS
    ? CGPath(rect: rect, transform: nil)
    : CGPath(roundedRect: rect, cornerWidth: 185, cornerHeight: 185, transform: nil)

ctx.saveGState()
ctx.addPath(squircle)
ctx.clip()
if let bg = CGGradient(colorsSpace: cs,
                       colors: [rgb(46, 51, 60), rgb(16, 18, 22)] as CFArray,
                       locations: [0, 1]) {
    ctx.drawLinearGradient(bg, start: CGPoint(x: 0, y: s), end: CGPoint(x: 0, y: 0), options: [])
}

// --- 絞り羽根 ---
let c = CGPoint(x: s/2, y: s/2)
// 角丸で削られないぶん、iOS では少し大きく描ける
let outer: CGFloat = forIOS ? 340 : 300
let innerR: CGFloat = forIOS ? 134 : 118
let blades = 6
let twist: CGFloat = .pi / 7 // 羽根を少しひねると絞りらしくなる

func pt(_ r: CGFloat, _ a: CGFloat) -> CGPoint {
    CGPoint(x: c.x + r * cos(a), y: c.y + r * sin(a))
}

for i in 0..<blades {
    let a0 = CGFloat(i) * 2 * .pi / CGFloat(blades) + .pi / 6
    let a1 = a0 + 2 * .pi / CGFloat(blades)

    let path = CGMutablePath()
    path.move(to: pt(outer, a0))
    path.addArc(center: c, radius: outer, startAngle: a0, endAngle: a1, clockwise: false)
    path.addLine(to: pt(innerR, a1 - twist))
    path.addLine(to: pt(innerR, a0 - twist))
    path.closeSubpath()

    // 光の当たり方を羽根ごとに変えて立体感を出す
    let t = CGFloat(i) / CGFloat(blades - 1)
    let r = 255 - Int(60 * t)
    let g = 170 - Int(60 * t)
    let b = 70  - Int(30 * t)
    ctx.addPath(path)
    ctx.setFillColor(rgb(r, g, b))
    ctx.fillPath()

    // 羽根の境界
    ctx.addPath(path)
    ctx.setStrokeColor(rgb(20, 16, 12, 0.55))
    ctx.setLineWidth(4)
    ctx.strokePath()
}

// --- 開口部を暗く抜いて奥行きを出す ---
let hole = CGMutablePath()
for i in 0..<blades {
    let a = CGFloat(i) * 2 * .pi / CGFloat(blades) + .pi / 6 - twist
    let p = pt(innerR, a)
    if i == 0 { hole.move(to: p) } else { hole.addLine(to: p) }
}
hole.closeSubpath()
ctx.addPath(hole)
ctx.setFillColor(rgb(12, 13, 16))
ctx.fillPath()

// 開口部の内側にわずかな反射
ctx.saveGState()
ctx.addPath(hole)
ctx.clip()
if let glow = CGGradient(colorsSpace: cs,
                         colors: [rgb(90, 120, 170, 0.55), rgb(12, 13, 16, 0)] as CFArray,
                         locations: [0, 1]) {
    ctx.drawRadialGradient(glow,
                           startCenter: CGPoint(x: c.x - 40, y: c.y + 45), startRadius: 0,
                           endCenter: c, endRadius: innerR * 1.5, options: [])
}
ctx.restoreGState()

// --- 上端の艶。macOS のアイコンらしさが出る ---
if let sheen = CGGradient(colorsSpace: cs,
                          colors: [rgb(255, 255, 255, 0.16), rgb(255, 255, 255, 0)] as CFArray,
                          locations: [0, 1]) {
    ctx.saveGState()
    ctx.addPath(squircle)
    ctx.clip()
    ctx.drawLinearGradient(sheen, start: CGPoint(x: 0, y: s - inset),
                           end: CGPoint(x: 0, y: s * 0.62), options: [])
    ctx.restoreGState()
}
ctx.restoreGState()

// --- 縁取り（角丸を自分で描く macOS 版のみ）---
if !forIOS {
    ctx.addPath(squircle)
    ctx.setStrokeColor(rgb(255, 255, 255, 0.10))
    ctx.setLineWidth(3)
    ctx.strokePath()
}

guard let image = ctx.makeImage() else { fatalError("画像化に失敗") }
let rep = NSBitmapImageRep(cgImage: image)
guard let png = rep.representation(using: .png, properties: [:]) else { fatalError("PNG 化に失敗") }
let target = CommandLine.arguments.dropFirst().first { !$0.hasPrefix("--") }
let out = URL(fileURLWithPath: target ?? "icon_1024.png")
try png.write(to: out)
print("書き出し: \(out.path)")
