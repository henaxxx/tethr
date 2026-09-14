import Foundation
import ImageCaptureCore

/// カード上のファイルを、必要な部分だけ読む。
///
/// RAW を丸ごと落とさずに一覧やプレビューを出すための読み方。iOS 版で実機を相手に詰めたもので、Mac 版と共有する
public enum CardFile {

    /// 指定した範囲を読む。返事が来ないものは 60 秒で諦める
    public static func read(_ file: ICCameraFile, offset: off_t, length: off_t) async -> Data? {
        await withCheckedContinuation { cont in
            let once = Once()
            file.requestReadData(atOffset: offset, length: length) { data, _ in
                guard once.claim() else { return }
                cont.resume(returning: data)
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + 60) {
                guard once.claim() else { return }
                cont.resume(returning: nil)
            }
        }
    }

    /// ImageCaptureCore が作る小さいサムネイル（JPEG）。大きさの指定はほとんど効かない
    public static func thumbnailData(_ file: ICCameraFile, maxPixel: Int = 320) async -> Data? {
        await withCheckedContinuation { cont in
            let once = Once()
            file.requestThumbnailData(options: [.imageSourceThumbnailMaxPixelSize: maxPixel]) { data, _ in
                guard once.claim() else { return }
                cont.resume(returning: data)
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + 60) {
                guard once.claim() else { return }
                cont.resume(returning: nil)
            }
        }
    }

    /// 撮影時のカメラの向き（TIFF の Orientation）。NEF の先頭だけを読む
    public static func orientation(_ file: ICCameraFile) async -> Int? {
        guard let header = await read(file, offset: 0, length: 2048) else { return nil }
        return NEF.orientation(in: header)
    }

    /// NEF に埋め込まれたいちばん大きい JPEG と、撮影時の向き。
    /// 先頭 128KB で位置を割り出し、その範囲だけを読む（11MB の NEF でも 1〜2MB で済む）
    public static func embeddedPreview(_ file: ICCameraFile) async -> (jpeg: Data, orientation: Int?)? {
        guard let header = await read(file, offset: 0, length: 128 * 1024) else { return nil }
        let orientation = NEF.orientation(in: header)
        guard let loc = NEF.largestPreview(in: header), loc.length > 0, loc.length < 40 * 1024 * 1024,
              let jpeg = await read(file, offset: off_t(loc.offset), length: off_t(loc.length)) else { return nil }
        return (jpeg, orientation)
    }
}
