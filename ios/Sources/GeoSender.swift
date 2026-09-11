import Foundation
import Network
import UIKit

/// Mac 版へ位置情報を送る。
///
/// Bonjour で相手を探し、直接繋いで送る。サーバもアカウントも要らない。
/// includePeerToPeer を有効にしているので、同じ Wi-Fi に居なくても
/// 端末同士が直接繋がる。
@MainActor
final class GeoSender: ObservableObject {

    struct Peer: Identifiable, Equatable {
        let id: String
        let name: String
        let endpoint: NWEndpoint
        static func == (a: Peer, b: Peer) -> Bool { a.id == b.id }
    }

    enum Status: Equatable {
        case idle
        case searching
        case sending(String)
        case sent(String)
        case failed(String)
    }

    /// Mac 側と揃えた取り決め
    private static let serviceType = "_tethr._tcp"
    private static let magic = Data("TETHR1".utf8)

    @Published private(set) var peers: [Peer] = []
    @Published private(set) var status: Status = .idle

    private var browser: NWBrowser?
    private var connection: NWConnection?

    private var params: NWParameters {
        let p = NWParameters.tcp
        p.includePeerToPeer = true
        return p
    }

    // MARK: 探索

    func startBrowsing() {
        guard browser == nil else { return }
        status = .searching
        let browser = NWBrowser(for: .bonjour(type: Self.serviceType, domain: nil), using: params)
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            Task { @MainActor in
                self?.peers = results.compactMap { result in
                    guard case .service(let name, _, _, _) = result.endpoint else { return nil }
                    return Peer(id: name, name: name, endpoint: result.endpoint)
                }
                .sorted { $0.name < $1.name }
            }
        }
        browser.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                if case .failed(let error) = state {
                    self?.status = .failed(error.localizedDescription)
                }
            }
        }
        browser.start(queue: .main)
        self.browser = browser
    }

    func stopBrowsing() {
        browser?.cancel()
        browser = nil
        peers = []
        if case .searching = status { status = .idle }
    }

    // MARK: 送信

    func send(_ log: GeoLogSnapshot, to peer: Peer) {
        connection?.cancel()
        status = .sending(peer.name)

        let body: Data
        do {
            body = try Self.frame(sender: UIDevice.current.name, log: log)
        } catch {
            status = .failed(String(localized: "送る内容を組み立てられませんでした"))
            return
        }

        let connection = NWConnection(to: peer.endpoint, using: params)
        self.connection = connection

        connection.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                guard let self else { return }
                switch state {
                case .ready:
                    connection.send(content: body, completion: .contentProcessed { error in
                        Task { @MainActor in
                            if let error {
                                self.status = .failed(error.localizedDescription)
                                connection.cancel()
                                return
                            }
                            self.awaitReply(connection, peer: peer)
                        }
                    })
                case .failed(let error):
                    self.status = .failed(error.localizedDescription)
                    connection.cancel()
                case .waiting(let error):
                    self.status = .failed(String(localized: "接続できません: \(error.localizedDescription)"))
                default:
                    break
                }
            }
        }
        connection.start(queue: .main)
    }

    /// 相手が受け取れたかを確かめてから完了にする。
    /// 送信 API の成功は「送出した」までしか保証しない。
    private func awaitReply(_ connection: NWConnection, peer: Peer) {
        connection.receive(minimumIncompleteLength: 2, maximumLength: 2) { [weak self] data, _, _, error in
            Task { @MainActor in
                guard let self else { return }
                defer { connection.cancel() }
                guard let data, error == nil else {
                    self.status = .failed(String(localized: "応答がありません"))
                    return
                }
                if String(decoding: data, as: UTF8.self) == "OK" {
                    self.status = .sent(peer.name)
                } else {
                    self.status = .failed(String(localized: "受け取りを拒否されました"))
                }
            }
        }
    }

    // MARK: 形式

    struct Envelope: Codable {
        let sender: String
        let payload: GeoLogSnapshot
    }

    private static func frame(sender: String, log: GeoLogSnapshot) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let body = try encoder.encode(Envelope(sender: sender, payload: log))
        var data = magic
        var length = UInt32(body.count).bigEndian
        withUnsafeBytes(of: &length) { data.append(contentsOf: $0) }
        data.append(body)
        return data
    }
}

/// 送信する中身。Mac 側の GeoPayload と同じ形。
struct GeoLogSnapshot: Codable {
    let generated: Date
    let shots: [String: GeoPoint]
    let track: [GeoPoint]
}
