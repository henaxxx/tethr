import Foundation
import CoreLocation

struct GeoPoint: Codable, Equatable {
    let time: Date
    let lat: Double
    let lon: Double
    let alt: Double?
    let accuracy: Double?

    init(_ location: CLLocation) {
        time = location.timestamp
        lat = location.coordinate.latitude
        lon = location.coordinate.longitude
        alt = location.verticalAccuracy > 0 ? location.altitude : nil
        accuracy = location.horizontalAccuracy > 0 ? location.horizontalAccuracy : nil
    }

    var location: CLLocation {
        CLLocation(latitude: lat, longitude: lon)
    }
}

/// 位置情報の記録。Mac へ渡すまで端末に残す。
///
/// 2 種類を持つ。
///   shots — 接続中に届いたカットの、ファイル名で確定した位置。
///           時刻の突き合わせが要らないので誤差が入らない。
///   track — 連続した軌跡。テザーしていない間に撮ったカットを
///           撮影時刻で拾うための保険。
///
/// 数日後に Mac へ渡すこともあるため、ディスクに永続化する。
@MainActor
final class GeoLog: ObservableObject {

    @Published private(set) var shots: [String: GeoPoint] = [:]
    @Published private(set) var track: [GeoPoint] = []

    private var pendingSaves = 0
    private static let filename = "geolog.json"

    private static var fileURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(filename)
    }

    init() { load() }

    var trackSpan: String? {
        guard let first = track.first?.time, let last = track.last?.time, track.count > 1 else { return nil }
        let minutes = Int(last.timeIntervalSince(first) / 60)
        if minutes < 60 { return String(localized: "\(minutes)分") }
        return String(localized: "\(minutes / 60)時間\(minutes % 60)分")
    }

    // MARK: 記録

    /// 指定した時刻にいちばん近い軌跡の点。撮影通知を受け取れなかったカットの位置を、撮影時刻から引く
    func location(near time: Date, within limit: TimeInterval = 120) -> CLLocation? {
        guard let nearest = track.min(by: {
            abs($0.time.timeIntervalSince(time)) < abs($1.time.timeIntervalSince(time))
        }), abs(nearest.time.timeIntervalSince(time)) <= limit else { return nil }
        return nearest.location
    }

    func recordShot(_ name: String, at location: CLLocation) {
        shots[name] = GeoPoint(location)
        scheduleSave()
    }

    /// 軌跡は間引いて溜める。
    /// 止まっている間の点を全部残しても、後段の突き合わせには寄与せず
    /// 転送量とファイルサイズだけが増える。
    func recordTrack(_ location: CLLocation) {
        if let last = track.last {
            let moved = location.distance(from: last.location)
            let elapsed = location.timestamp.timeIntervalSince(last.time)
            guard moved >= 10 || elapsed >= 30 else { return }
        }
        track.append(GeoPoint(location))
        scheduleSave()
    }

    func clear() {
        shots = [:]
        track = []
        try? FileManager.default.removeItem(at: Self.fileURL)
    }

    // MARK: 受け渡し用

    typealias Payload = GeoLogSnapshot

    func snapshot() -> GeoLogSnapshot {
        GeoLogSnapshot(generated: Date(), shots: shots, track: track)
    }

    func payload() -> Data? {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return try? encoder.encode(snapshot())
    }

    // MARK: 永続化

    /// 1 点ごとに書くと点が増えるほど重くなる。まとめて書く。
    private func scheduleSave() {
        pendingSaves += 1
        guard pendingSaves >= 20 else { return }
        save()
    }

    func save() {
        pendingSaves = 0
        guard let data = payload() else { return }
        try? data.write(to: Self.fileURL, options: .atomic)
    }

    private func load() {
        guard let data = try? Data(contentsOf: Self.fileURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let payload = try? decoder.decode(Payload.self, from: data) else { return }
        shots = payload.shots
        track = payload.track
    }
}
