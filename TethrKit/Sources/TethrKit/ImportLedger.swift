import Foundation

/// 取り込んだカットの控え（iOS と Mac で共通）。
///
/// 保存先にファイルがあるか・起動中に取り込んだかだけで判定すると、アプリを起動し直したり、
/// 取り込んだ後で NAS などへ移したりしたカットが「未取り込み」に戻り、二重に取り込んでしまう。
/// カメラのシリアル・ファイル名・大きさ・撮影時刻の組で覚えておく（ファイル番号は 9999 で一巡するので、名前だけでは足りない）。
///
/// 1 件は 40 バイトほど。上限を超えたら古いものから捨てるので、ファイルは 1MB に届かない。
/// 書き込みは少し待ってまとめる（まとめて取り込むと 1 秒に何件も増えるため）
@MainActor
public final class ImportLedger {
    /// 覚えておく件数の上限
    public static let limit = 20_000

    private let url: URL
    private let log: (String) -> Void
    private var keys: Set<String> = []
    /// 古い順。上限を超えたときに捨てる順番
    private var order: [String] = []
    private var saveTask: Task<Void, Never>?

    public init(url: URL, log: @escaping (String) -> Void = { _ in }) {
        self.url = url
        self.log = log
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? Data(contentsOf: url),
           let saved = try? JSONDecoder().decode([String].self, from: data) {
            order = saved
            keys = Set(saved)
        }
    }

    public var count: Int { order.count }

    private func key(serial: String, name: String, size: Int64, captured: Date?) -> String {
        "\(serial)|\(name)|\(size)|\(Int(captured?.timeIntervalSince1970 ?? 0))"
    }

    public func contains(serial: String, name: String, size: Int64, captured: Date?) -> Bool {
        keys.contains(key(serial: serial, name: name, size: size, captured: captured))
    }

    public func record(serial: String, name: String, size: Int64, captured: Date?) {
        let key = key(serial: serial, name: name, size: size, captured: captured)
        guard keys.insert(key).inserted else { return }
        order.append(key)
        if order.count > Self.limit {
            let dropped = order.prefix(order.count - Self.limit)
            keys.subtract(dropped)
            order.removeFirst(dropped.count)
        }
        scheduleSave()
    }

    /// すぐに書き出す（アプリが背面に回るときなど）
    public func flush() {
        saveTask?.cancel()
        saveTask = nil
        save()
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            self?.save()
            self?.saveTask = nil
        }
    }

    private func save() {
        do {
            try JSONEncoder().encode(order).write(to: url, options: .atomic)
        } catch {
            log("取り込みの控えを保存できない: \(error.localizedDescription)")
        }
    }
}
