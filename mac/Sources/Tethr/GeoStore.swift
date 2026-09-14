import Foundation

/// iPhone から受け取った位置情報を、アプリ全体で 1 つ持つ。
///
/// 以前は「位置情報を付与」ウインドウを開いている間だけ待ち受けていた。
/// カードからの取り込みで位置を書き込むので、起動している間はずっと待ち受け、
/// 最後に受け取った内容はディスクに残す（Mac を再起動しても使える）
@MainActor
final class GeoStore: ObservableObject {
    @Published private(set) var payload: GeoPayload?
    @Published private(set) var sender: String?
    @Published private(set) var receivedAt: Date?

    let receiver = GeoReceiver()

    private struct Saved: Codable {
        let sender: String
        let receivedAt: Date
        let payload: GeoPayload
    }

    private static let url: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Tethr", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("geo-latest.json")
    }()

    init() {
        load()
        receiver.onReceive = { [weak self] envelope in self?.adopt(envelope) }
        receiver.start()
    }

    private func adopt(_ envelope: GeoLink.Envelope) {
        payload = envelope.payload
        sender = envelope.sender
        receivedAt = Date()
        let saved = Saved(sender: envelope.sender, receivedAt: Date(), payload: envelope.payload)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        do {
            try encoder.encode(saved).write(to: Self.url, options: .atomic)
        } catch {
            Log.write("受け取った位置情報を保存できない: \(error.localizedDescription)")
        }
    }

    private func load() {
        guard let data = try? Data(contentsOf: Self.url) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let saved = try? decoder.decode(Saved.self, from: data) else { return }
        payload = saved.payload
        sender = saved.sender
        receivedAt = saved.receivedAt
    }
}
