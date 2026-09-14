import AppKit
import ImageIO

/// カメラが記録した向き（TIFF の Orientation）で絵を回す。
///
/// NEF に埋め込まれた JPEG やカメラのサムネイルは、縦に構えて撮っても横長の画素のまま届く。
/// 向きは NEF の先頭（IFD0）にだけある。すでに縦長になっている絵は回さない（二重に回さないため）
enum OrientedImage {
    static func make(_ data: Data, orientation: Int?, maxPixel: Int? = nil) -> NSImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let cg: CGImage?
        if let maxPixel {
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            ]
            cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        } else {
            cg = CGImageSourceCreateImageAtIndex(source, 0, nil)
        }
        guard let cg else { return nil }
        let rotated = rotate(cg, orientation: orientation) ?? cg
        return NSImage(cgImage: rotated, size: NSSize(width: rotated.width, height: rotated.height))
    }

    /// 横長の画素のときだけ、6 と 8 で 90 度、3 で 180 度回す
    static func rotate(_ image: CGImage, orientation: Int?) -> CGImage? {
        guard let orientation, [3, 6, 8].contains(orientation) else { return nil }
        if orientation != 3 && image.width <= image.height { return nil }
        let quarter = orientation != 3
        let width = quarter ? image.height : image.width
        let height = quarter ? image.width : image.height
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: image.colorSpace ?? CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        // CGContext は原点が左下。表示のために時計回り（6）・反時計回り（8）・180 度（3）回す
        switch orientation {
        case 6:
            context.translateBy(x: 0, y: CGFloat(height))
            context.rotate(by: -.pi / 2)
        case 8:
            context.translateBy(x: CGFloat(width), y: 0)
            context.rotate(by: .pi / 2)
        default:
            context.translateBy(x: CGFloat(width), y: CGFloat(height))
            context.rotate(by: .pi)
        }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return context.makeImage()
    }
}
