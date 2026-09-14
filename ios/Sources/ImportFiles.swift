import Foundation
import ImageIO
import TethrKit
import UniformTypeIdentifiers

/// 取り込みの途中で端末に置くファイル。
///
/// NEF は写真アプリへ移すまでの一時置き場（Caches/Imports）に読み出す。
/// 大きな写真の表示に使う JPEG は NEF から取り出して Caches/Previews に置き、新しいものから 40 枚だけ残す。
/// どちらも起動のたびに片付ける（以前は Documents に NEF を置いたまま消しておらず、40 枚・約 440MB 溜まっていた）
enum ImportFiles {

    private static let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
    static let downloads = caches.appendingPathComponent("Imports", isDirectory: true)
    private static let previews = caches.appendingPathComponent("Previews", isDirectory: true)
    /// 表示用 JPEG を残す枚数（1 枚 1.5MB ほど）
    private static let previewLimit = 40

    /// 起動時に、前回の読み出しの残りと、以前 Documents に置いていた写真を消す
    static func cleanUp() {
        Task.detached(priority: .utility) {
            let fm = FileManager.default
            try? fm.removeItem(at: downloads)
            try? fm.removeItem(at: previews)
            let documents = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
            let photoExtensions: Set<String> = ["nef", "nrw", "jpg", "jpeg", "tif", "tiff", "dng", "cr2", "cr3",
                                                "arw", "raf", "orf", "rw2", "heic", "heif", "mov", "mp4"]
            let files = (try? fm.contentsOfDirectory(at: documents, includingPropertiesForKeys: [.fileSizeKey])) ?? []
            var removed = 0
            var bytes = 0
            for file in files where photoExtensions.contains(file.pathExtension.lowercased()) {
                bytes += (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                if (try? fm.removeItem(at: file)) != nil { removed += 1 }
            }
            if removed > 0 {
                DebugLog.write("以前の取り込みで残っていた写真を消した: \(removed) 件 \(bytes / 1_000_000)MB")
            }
        }
    }

    /// 読み出したファイルから、表示用の JPEG を取り出してキャッシュに置く。
    ///
    /// NEF に埋め込まれた JPEG には向きが入っていない（向きは NEF 本体の IFD0 だけ）ので、
    /// 画素を作り直さずに向きだけを書き添える。JPEG で撮ったカットは、そのまま複製する
    static func cachePreview(from url: URL, name: String) async -> URL? {
        await Task.detached(priority: .utility) { () -> URL? in
            let fm = FileManager.default
            try? fm.createDirectory(at: previews, withIntermediateDirectories: true)
            let target = previews.appendingPathComponent((name as NSString).deletingPathExtension + ".jpg")
            try? fm.removeItem(at: target)
            guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
            defer { try? handle.close() }
            let header = (try? handle.read(upToCount: 128 * 1024)) ?? Data()

            if let location = NEF.largestPreview(in: header), location.length > 0, location.length < 40 * 1024 * 1024,
               (try? handle.seek(toOffset: UInt64(location.offset))) != nil,
               let jpeg = try? handle.read(upToCount: location.length), jpeg.count == location.length {
                guard write(jpeg, to: target, orientation: NEF.orientation(in: header)) else { return nil }
            } else if header.starts(with: [0xFF, 0xD8]) {
                guard (try? fm.copyItem(at: url, to: target)) != nil else { return nil }
            } else {
                return nil
            }
            trim()
            return target
        }.value
    }

    /// 画素はそのまま、向きだけを付けて書く。付けられなければそのまま書く
    private static func write(_ jpeg: Data, to target: URL, orientation: Int?) -> Bool {
        if let orientation, orientation != 1,
           let source = CGImageSourceCreateWithData(jpeg as CFData, nil),
           let destination = CGImageDestinationCreateWithURL(target as CFURL, UTType.jpeg.identifier as CFString, 1, nil) {
            let options: [CFString: Any] = [kCGImageDestinationOrientation: orientation]
            if CGImageDestinationCopyImageSource(destination, source, options as CFDictionary, nil) { return true }
        }
        return (try? jpeg.write(to: target)) != nil
    }

    /// 新しいものから決まった枚数だけ残す
    private static func trim() {
        let fm = FileManager.default
        let files = (try? fm.contentsOfDirectory(at: previews, includingPropertiesForKeys: [.creationDateKey])) ?? []
        guard files.count > previewLimit else { return }
        let sorted = files.sorted {
            let a = (try? $0.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
            let b = (try? $1.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
            return a < b
        }
        for file in sorted.prefix(files.count - previewLimit) {
            try? fm.removeItem(at: file)
        }
    }
}
