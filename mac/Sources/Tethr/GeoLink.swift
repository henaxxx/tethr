import Foundation
import Network

/// iOS 版との受け渡しの取り決め。
///
/// 同じ内容を iOS 側にも置く。共有フレームワークを挟むほどの分量ではなく、
/// 独立して動く 2 本のアプリなので、形式だけを合わせる。
enum GeoLink {
    static let serviceType = "_tethr._tcp"

    /// 先頭に目印と長さを置く。TCP は境界を保たないので、
    /// どこまでが 1 通ぶんかを自分で示す必要がある。
    static let magic = Data("TETHR1".utf8)
    static let maxPayload = 32 * 1024 * 1024

    struct Envelope: Codable {
        let sender: String
        let payload: GeoPayload
    }

    static func frame(_ envelope: Envelope) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let body = try encoder.encode(envelope)
        var data = magic
        var length = UInt32(body.count).bigEndian
        withUnsafeBytes(of: &length) { data.append(contentsOf: $0) }
        data.append(body)
        return data
    }

    static func decode(_ body: Data) throws -> Envelope {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(Envelope.self, from: body)
    }
}

/// iPhone からの位置情報を待ち受ける。
///
/// Bonjour で自分を広告し、見つけてもらう。
/// includePeerToPeer を有効にしているので、同じ Wi-Fi に居なくても
/// 端末同士が直接繋がる（AirDrop と同じ仕組みを自前の用途で使う形）。
@MainActor
final class GeoReceiver: ObservableObject {

    enum State: Equatable {
        case stopped
        case waiting(String)          // 広告している名前
        case receiving
        case received(String, Date)   // 送り主, 受信時刻
        case failed(String)
    }

    @Published private(set) var state: State = .stopped
    @Published private(set) var lastPayload: GeoPayload?
    /// 1 通受け取り終えた
    var onReceive: ((GeoLink.Envelope) -> Void)?

    private var listener: NWListener?
    private var connections: [NWConnection] = []

    var serviceName: String {
        Host.current().localizedName ?? "Mac"
    }

    func start() {
        guard listener == nil else { return }
        do {
            let params = NWParameters.tcp
            params.includePeerToPeer = true
            let listener = try NWListener(using: params)
            listener.service = NWListener.Service(name: serviceName, type: GeoLink.serviceType)

            listener.stateUpdateHandler = { [weak self] state in
                Task { @MainActor in
                    guard let self else { return }
                    switch state {
                    case .ready: self.state = .waiting(self.serviceName)
                    case .failed(let error): self.state = .failed(error.localizedDescription)
                    case .cancelled: self.state = .stopped
                    default: break
                    }
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                Task { @MainActor in self?.accept(connection) }
            }
            listener.start(queue: .main)
            self.listener = listener
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        connections.forEach { $0.cancel() }
        connections = []
        state = .stopped
    }

    // MARK: 受信

    private func accept(_ connection: NWConnection) {
        connections.append(connection)
        state = .receiving
        connection.start(queue: .main)
        readHeader(connection)
    }

    private func readHeader(_ connection: NWConnection) {
        let headerSize = GeoLink.magic.count + 4
        connection.receive(minimumIncompleteLength: headerSize, maximumLength: headerSize) { [weak self] data, _, _, error in
            Task { @MainActor in
                guard let self else { return }
                guard let data, data.count == headerSize, error == nil else {
                    self.finish(connection, error: String(localized: "受信できませんでした"))
                    return
                }
                guard data.prefix(GeoLink.magic.count) == GeoLink.magic else {
                    self.finish(connection, error: String(localized: "形式が違います"))
                    return
                }
                let lengthBytes = data.suffix(4)
                let length = lengthBytes.reduce(0) { UInt32($0) << 8 | UInt32($1) }
                guard length > 0, length <= UInt32(GeoLink.maxPayload) else {
                    self.finish(connection, error: String(localized: "大きさが不正です"))
                    return
                }
                self.readBody(connection, length: Int(length))
            }
        }
    }

    private func readBody(_ connection: NWConnection, length: Int) {
        connection.receive(minimumIncompleteLength: length, maximumLength: length) { [weak self] data, _, _, error in
            Task { @MainActor in
                guard let self else { return }
                guard let data, data.count == length, error == nil else {
                    self.finish(connection, error: String(localized: "本体を受信できませんでした"))
                    return
                }
                do {
                    let envelope = try GeoLink.decode(data)
                    self.lastPayload = envelope.payload
                    self.state = .received(envelope.sender, Date())
                    self.onReceive?(envelope)
                    Log.write("位置情報を受信: \(envelope.sender) から "
                              + "shots \(envelope.payload.shots.count) / track \(envelope.payload.track.count)")
                    connection.send(content: Data("OK".utf8), completion: .contentProcessed { _ in
                        connection.cancel()
                    })
                } catch {
                    self.finish(connection, error: String(localized: "内容を解釈できませんでした"))
                }
            }
        }
    }

    private func finish(_ connection: NWConnection, error: String) {
        Log.write("受信に失敗: \(error)")
        state = .failed(error)
        connection.send(content: Data("NG".utf8), completion: .contentProcessed { _ in
            connection.cancel()
        })
        // 次の接続はそのまま待ち続ける
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            if case .failed = self.state { self.state = .waiting(self.serviceName) }
        }
    }
}
