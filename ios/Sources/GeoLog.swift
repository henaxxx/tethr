import Foundation
import CoreLocation

/// 軌跡の間隔の基準。ここに関わる時間はすべてこの 1 つから決める。
///   - 記録している間は、点と点の間がこれを超えない（立ち止まっている間は LocationProvider が打ち直す）
///   - 撮影時刻から位置を引くとき、前後の点がこれ以内なら記録中だったとみなす
///   - 軌跡のファイルへの書き出しもこの間隔
enum TrackTiming {
    static let interval: TimeInterval = 5 * 60
}

struct GeoPoint: Codable, Equatable {
    let time: Date
    let lat: Double
    let lon: Double
    let alt: Double?
    let accuracy: Double?

    init(_ location: CLLocation, time: Date? = nil) {
        self.time = time ?? location.timestamp
        lat = location.coordinate.latitude
        lon = location.coordinate.longitude
        alt = location.verticalAccuracy > 0 ? location.altitude : nil
        accuracy = location.horizontalAccuracy > 0 ? location.horizontalAccuracy : nil
    }

    var location: CLLocation {
        CLLocation(latitude: lat, longitude: lon)
    }

    /// 写真に付ける形。時刻は撮影時刻にしておく
    func location(at time: Date) -> CLLocation {
        CLLocation(coordinate: CLLocationCoordinate2D(latitude: lat, longitude: lon),
                   altitude: alt ?? 0, horizontalAccuracy: accuracy ?? -1,
                   verticalAccuracy: alt == nil ? -1 : 10, timestamp: time)
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

    private static let filename = "geolog.json"

    private static var fileURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(filename)
    }

    init() { load() }

    /// 軌跡の最初の点から最後の点まで。
    ///
    /// 以前は差を「記録時間 11時間6分」と出していたが、消去してからの点を全部持っているので、
    /// アプリを使っていなかった夜の間まで含んでいた（実際に記録していたのは 1 時間ほど）。
    /// 長さではなく、いつからいつまでかを出す
    var trackPeriod: String? {
        guard let first = track.first?.time, let last = track.last?.time, track.count > 1 else { return nil }
        let calendar = Calendar.current
        let time = Date.FormatStyle(date: .omitted, time: .shortened)
        let dayAndTime = Date.FormatStyle().month(.defaultDigits).day().hour().minute()
        if calendar.isDate(first, inSameDayAs: last) {
            let range = "\(first.formatted(time))〜\(last.formatted(time))"
            return calendar.isDateInToday(first) ? range : "\(first.formatted(.dateTime.month(.defaultDigits).day())) \(range)"
        }
        return "\(first.formatted(dayAndTime))〜\(last.formatted(dayAndTime))"
    }

    // MARK: 撮影時刻から位置を引く

    /// 軌跡から、ある時刻にいた場所を見積もる。撮影通知を受け取れなかったカットやカード内のカットに使う。
    ///
    /// 1. 前後の点の間が 5 分以内なら、その間を埋める（ほぼ動いていなければ近い方の点、動いていれば時間で按分）
    /// 2. 軌跡の端（記録の始まる前・終わった後）は、端の点から 5 分以内ならその点
    /// 3. それより離れていたら付けない
    ///
    /// 空白を埋めてよいのは「記録していたが点が出なかった」ときだけ。立ち止まっている間も 5 分経つ前に点を打つので
    /// （LocationProvider の heartbeat）、5 分を超える空白はアプリが記録していなかった時間になる。
    /// そこを埋めると、家を出てアプリを閉じ、外で撮って帰ってきたカットが家の位置になる
    func estimateLocation(at time: Date) -> CLLocation? {
        guard !track.isEmpty else { return nil }
        // 軌跡は古い順。time 以降で最初の点を二分探索で探す
        var low = 0, high = track.count
        while low < high {
            let mid = (low + high) / 2
            if track[mid].time < time { low = mid + 1 } else { high = mid }
        }
        let before = low > 0 ? track[low - 1] : nil
        let after = low < track.count ? track[low] : nil

        let interval = TrackTiming.interval
        guard let before, let after else {
            // 軌跡の端。記録を始める少し前や、閉じる少し前に撮ったカット
            guard let edge = before ?? after, abs(edge.time.timeIntervalSince(time)) <= interval else { return nil }
            return edge.location(at: time)
        }
        guard after.time.timeIntervalSince(before.time) <= interval else {
            // 記録していなかった空白。空白の縁のすぐそばで撮ったものだけは、縁の点を使う
            let edge = time.timeIntervalSince(before.time) <= after.time.timeIntervalSince(time) ? before : after
            return abs(edge.time.timeIntervalSince(time)) <= interval ? edge.location(at: time) : nil
        }
        let apart = after.location.distance(from: before.location)
        if apart <= 50 {
            let closer = time.timeIntervalSince(before.time) <= after.time.timeIntervalSince(time) ? before : after
            return closer.location(at: time)
        }
        let fraction = time.timeIntervalSince(before.time) / after.time.timeIntervalSince(before.time)
        let coordinate = CLLocationCoordinate2D(latitude: before.lat + (after.lat - before.lat) * fraction,
                                                longitude: before.lon + (after.lon - before.lon) * fraction)
        // 按分した位置は、前後の点の離れ具合の半分くらいは外れうる
        let accuracy = max(before.accuracy ?? 0, after.accuracy ?? 0, apart / 2)
        return CLLocation(coordinate: coordinate, altitude: before.alt ?? 0, horizontalAccuracy: accuracy,
                          verticalAccuracy: before.alt == nil ? -1 : 10, timestamp: time)
    }

    // MARK: 記録

    /// カットの位置を控える。時刻は位置を測った時刻ではなく、撮影の時刻にする。
    /// 立ち止まって衛星を止めている間は、何時間も前に測った位置を使うので、測った時刻だと
    /// カード取り込みでファイル名を照合するときの時刻の確認に落ちていた。
    /// カットはたまにしか増えず、失うと取り返せないので、その場で書き出す
    func recordShot(_ name: String, at location: CLLocation, time: Date) {
        shots[name] = GeoPoint(location, time: time)
        save()
    }

    /// 軌跡は間引いて溜める。
    /// 止まっている間の点を全部残しても、後段の突き合わせには寄与せず
    /// 転送量とファイルサイズだけが増える。
    func recordTrack(_ location: CLLocation) {
        if let last = track.last {
            guard location.timestamp > last.time else { return }
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
    ///
    /// 以前は 20 点溜まるまで書かなかった。立ち止まっていると点がなかなか溜まらず、その間にアプリが
    /// 終了させられると（入れ直し、スワイプで終了、背面での終了）、テザーで確定した位置ごと消えていた。
    /// いまは軌跡の間隔（5 分）ごとに書く。カットの位置はその場で、背面に回るときも必ず書くので、
    /// 突然終了しても失うのは直近 5 分の軌跡まで
    private func scheduleSave() {
        guard Date().timeIntervalSince(lastSaved) >= TrackTiming.interval else { return }
        save()
    }

    private var lastSaved = Date()

    func save() {
        lastSaved = Date()
        guard let data = payload() else { return }
        try? data.write(to: Self.fileURL, options: .atomic)
    }

    private func load() {
        guard let data = try? Data(contentsOf: Self.fileURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let payload = try? decoder.decode(Payload.self, from: data) else { return }
        shots = payload.shots
        // 位置の見積もりは二分探索なので、古い順を保証しておく
        track = payload.track.sorted { $0.time < $1.time }
    }
}
