import Foundation
import UIKit
import ImageIO
import CoreLocation

/// カード上の 1 カット。実体はカメラ側にあり、必要になった時だけ取り込む。
struct Shot: Identifiable, Equatable {
    let id = UUID()
    let name: String
    let size: Int
    let captured: Date?
    /// 一覧用の小さい絵
    var thumbnail: UIImage?
    /// プレビュー用の大きい絵。選択されたときだけ取りに行く。
    var preview: UIImage?
    /// 写真アプリへ保存済みか
    var savedToPhotos = false
    /// このカットが届いた瞬間の端末の位置。取り込み時に付与する。
    var location: CLLocation?
    /// 端末内に取り込み済みなら、その場所
    var localURL: URL?

    var sizeText: String {
        size >= 1_000_000 ? "\(size / 1_000_000)MB" : "\(size / 1000)KB"
    }

    static func == (a: Shot, b: Shot) -> Bool { a.id == b.id }
}


enum Preview {
    /// NEF に埋め込まれた JPEG から表示用の画像を作る。
    /// RAW を展開すると桁違いに遅いので、埋め込みをそのまま使う。
    static func load(_ url: URL, maxPixel: Int = 2400) async -> UIImage? {
        await Task.detached(priority: .userInitiated) { () -> UIImage? in
            guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
            let opts: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageIfAbsent: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixel,
                kCGImageSourceCreateThumbnailWithTransform: true,
            ]
            guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
            return UIImage(cgImage: cg)
        }.value
    }
}
