import Foundation
import UIKit

/// NEF（Nikon の RAW）に埋め込まれた JPEG の位置を割り出す。
///
/// NEF は TIFF 構造で、本体の RAW データとは別に
/// 撮影画像と同じ画角のフルサイズ JPEG を内包している。
/// ImageCaptureCore のサムネイル要求では小さい絵しか返らないため、
/// ファイルの構造を自前で辿り、その JPEG の範囲だけを部分読み出しする。
/// 11MB の NEF 全体を落とさずに、フル解像度のプレビューが得られる。
enum NEF {

    struct Location {
        let offset: Int
        let length: Int
    }

    /// TIFF のタグ
    private enum Tag: UInt16 {
        case subIFDs                 = 0x014A
        case compression             = 0x0103
        case stripOffsets            = 0x0111
        case stripByteCounts         = 0x0117
        case jpegInterchangeFormat   = 0x0201
        case jpegInterchangeLength   = 0x0202
        case exifIFD                 = 0x8769
    }

    /// 先頭部分だけを渡せばよい。IFD はファイル冒頭に固まっている。
    /// 見つかった中で最も大きい JPEG を返す。
    static func largestPreview(in header: Data) -> Location? {
        guard header.count > 8 else { return nil }
        let start = header.startIndex

        let byteOrder = (header[start], header[start + 1])
        let bigEndian: Bool
        switch byteOrder {
        case (0x4D, 0x4D): bigEndian = true    // "MM"
        case (0x49, 0x49): bigEndian = false   // "II"
        default: return nil
        }

        let r = Cursor(data: header, bigEndian: bigEndian)
        guard r.u16(at: 2) == 42 else { return nil }
        guard let ifd0 = r.u32(at: 4).map(Int.init) else { return nil }

        var candidates: [Location] = []
        var visited: Set<Int> = []
        var queue: [Int] = [ifd0]

        // IFD は入れ子になっている。SubIFDs と Exif IFD を辿る。
        while let offset = queue.popLast() {
            guard !visited.contains(offset) else { continue }
            visited.insert(offset)
            guard let entries = r.entries(at: offset) else { continue }

            var jpegOffset: Int?
            var jpegLength: Int?
            var stripOffset: Int?
            var stripLength: Int?
            var compression: Int?

            for e in entries {
                switch Tag(rawValue: e.tag) {
                case .subIFDs:
                    queue.append(contentsOf: r.values(of: e))
                case .exifIFD:
                    queue.append(contentsOf: r.values(of: e))
                case .jpegInterchangeFormat:
                    jpegOffset = r.values(of: e).first
                case .jpegInterchangeLength:
                    jpegLength = r.values(of: e).first
                case .stripOffsets:
                    if r.values(of: e).count == 1 { stripOffset = r.values(of: e).first }
                case .stripByteCounts:
                    if r.values(of: e).count == 1 { stripLength = r.values(of: e).first }
                case .compression:
                    compression = r.values(of: e).first
                case .none:
                    break
                }
            }

            if let o = jpegOffset, let l = jpegLength, l > 0 {
                candidates.append(Location(offset: o, length: l))
            }
            // 圧縮方式が JPEG (6) のときは、ストリップがそのまま JPEG になっている
            if compression == 6, let o = stripOffset, let l = stripLength, l > 0 {
                candidates.append(Location(offset: o, length: l))
            }
        }

        return candidates.max { $0.length < $1.length }
    }

    /// 撮影時のカメラの向き（TIFF の Orientation、1〜8）。IFD0 にだけ入っている。
    ///
    /// 埋め込みの JPEG には向きが書かれていない（D300 の JpgFromRaw を exiftool で確認）。
    /// カメラを縦に構えて撮っても、JPEG の画素は横長のまま届く
    static func orientation(in header: Data) -> Int? {
        guard header.count > 8 else { return nil }
        let start = header.startIndex
        let bigEndian: Bool
        switch (header[start], header[start + 1]) {
        case (0x4D, 0x4D): bigEndian = true
        case (0x49, 0x49): bigEndian = false
        default: return nil
        }
        let r = Cursor(data: header, bigEndian: bigEndian)
        guard r.u16(at: 2) == 42, let ifd0 = r.u32(at: 4).map(Int.init),
              let entry = r.entries(at: ifd0)?.first(where: { $0.tag == 0x0112 }),
              let value = r.values(of: entry).first, (1...8).contains(value)
        else { return nil }
        return value
    }

    // MARK: バイト列の読み取り

    private struct Entry {
        let tag: UInt16
        let type: UInt16
        let count: Int
        let payloadOffset: Int   // 値そのもの、または値の位置
    }

    private struct Cursor {
        let data: Data
        let bigEndian: Bool

        private func byte(_ i: Int) -> UInt8? {
            let idx = data.startIndex + i
            return idx < data.endIndex ? data[idx] : nil
        }

        func u16(at i: Int) -> UInt16? {
            guard let a = byte(i), let b = byte(i + 1) else { return nil }
            return bigEndian ? UInt16(a) << 8 | UInt16(b) : UInt16(b) << 8 | UInt16(a)
        }

        func u32(at i: Int) -> UInt32? {
            guard let a = byte(i), let b = byte(i + 1),
                  let c = byte(i + 2), let d = byte(i + 3) else { return nil }
            return bigEndian
                ? UInt32(a) << 24 | UInt32(b) << 16 | UInt32(c) << 8 | UInt32(d)
                : UInt32(d) << 24 | UInt32(c) << 16 | UInt32(b) << 8 | UInt32(a)
        }

        /// IFD は「エントリ数 → 12 バイトのエントリ×N」という並び
        func entries(at offset: Int) -> [Entry]? {
            guard let count = u16(at: offset), count > 0, count < 512 else { return nil }
            var result: [Entry] = []
            for i in 0..<Int(count) {
                let base = offset + 2 + i * 12
                guard let tag = u16(at: base),
                      let type = u16(at: base + 2),
                      let n = u32(at: base + 4) else { break }
                result.append(Entry(tag: tag, type: type, count: Int(n), payloadOffset: base + 8))
            }
            return result
        }

        /// SHORT / LONG の値を取り出す。
        /// 4 バイトに収まる場合は値が直接埋まっていて、
        /// 超える場合は別の位置を指している。
        func values(of e: Entry) -> [Int] {
            let unit = e.type == 3 ? 2 : 4
            let total = unit * e.count
            let base = total <= 4 ? e.payloadOffset : Int(u32(at: e.payloadOffset) ?? 0)
            guard base > 0 || total <= 4 else { return [] }

            var out: [Int] = []
            for i in 0..<min(e.count, 64) {
                let at = base + i * unit
                if unit == 2 {
                    guard let v = u16(at: at) else { break }
                    out.append(Int(v))
                } else {
                    guard let v = u32(at: at) else { break }
                    out.append(Int(v))
                }
            }
            return out
        }
    }
}

extension UIImage {
    /// カメラが記録した向きを付ける。画素はそのままで、表示のときに回る。
    ///
    /// 横長のまま届いた絵にだけ付ける。すでに誰か（ImageCaptureCore など）が回して縦長になっている絵や、
    /// 向きの付いた絵に重ねて付けると、二重に回ってしまうため
    func applyingCameraOrientation(_ tiff: Int?) -> UIImage {
        guard let tiff, imageOrientation == .up, let cg = cgImage else { return self }
        let orientation: UIImage.Orientation
        switch tiff {
        case 3: orientation = .down
        case 6: orientation = .right       // 表示するには時計回りに 90 度
        case 8: orientation = .left        // 表示するには反時計回りに 90 度
        default: return self
        }
        if tiff != 3 && size.width <= size.height { return self }
        return UIImage(cgImage: cg, scale: scale, orientation: orientation)
    }
}
