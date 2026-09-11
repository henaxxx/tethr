import Foundation
import AppKit
import ImageIO

struct ShotMeta {
    var pixelWidth: Int = 0
    var pixelHeight: Int = 0
    var iso: Int?
    var exposureTime: Double?
    var fNumber: Double?
    var captured: Date?

    /// 1/250 形式。1秒以上は 1.3" 形式。
    var shutterText: String? {
        guard let t = exposureTime else { return nil }
        if t >= 1 { return String(format: "%.1f\"", t) }
        return "1/\(Int((1 / t).rounded()))"
    }

    var summary: String {
        [shutterText, fNumber.map { "f/\(($0 * 10).rounded() / 10)".replacingOccurrences(of: ".0", with: "") },
         iso.map { "ISO \($0)" }]
            .compactMap { $0 }
            .joined(separator: "  ")
    }
}

struct Shot: Identifiable {
    let id = UUID()
    let url: URL
    let arrived: Date
    var thumbnail: NSImage?
    var meta = ShotMeta()

    var name: String { url.lastPathComponent }
}

enum Thumbnailer {

    /// NEF に埋め込まれた JPEG プレビューを使う。
    /// kCGImageSourceCreateThumbnailFromImageAlways を指定すると RAW を
    /// フルデコードしてしまい 20 倍遅くなる（実測 16ms → 313ms）。
    static func load(_ url: URL, maxPixel: Int) -> (NSImage, ShotMeta)? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }

        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageIfAbsent: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }

        var meta = ShotMeta()
        if let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] {
            meta.pixelWidth = props[kCGImagePropertyPixelWidth] as? Int ?? cg.width
            meta.pixelHeight = props[kCGImagePropertyPixelHeight] as? Int ?? cg.height
            if let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any] {
                meta.exposureTime = exif[kCGImagePropertyExifExposureTime] as? Double
                meta.fNumber = exif[kCGImagePropertyExifFNumber] as? Double
                meta.iso = (exif[kCGImagePropertyExifISOSpeedRatings] as? [Int])?.first
                if let s = exif[kCGImagePropertyExifDateTimeOriginal] as? String {
                    let df = DateFormatter()
                    df.dateFormat = "yyyy:MM:dd HH:mm:ss"
                    meta.captured = df.date(from: s)
                }
            }
        }
        let image = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        return (image, meta)
    }
}
