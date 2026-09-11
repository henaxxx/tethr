import Foundation

/// iOS 版から受け取る位置情報。
///
/// 2 種類が入っている。
///   shots — ファイル名で確定した位置。テザー中に届いたカット。
///           時刻の突き合わせが要らないので誤差がない。
///   track — 連続した軌跡。テザーしていない間に撮ったカットを
///           撮影時刻で拾うためのもの。
struct GeoPayload: Codable {
    let generated: Date
    let shots: [String: GeoPoint]
    let track: [GeoPoint]

    static func decode(_ data: Data) throws -> GeoPayload {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(GeoPayload.self, from: data)
    }

    var trackRange: (start: Date, end: Date)? {
        guard let first = track.first?.time, let last = track.last?.time else { return nil }
        return (first, last)
    }
}

struct GeoPoint: Codable {
    let time: Date
    let lat: Double
    let lon: Double
    let alt: Double?
    let accuracy: Double?
}
