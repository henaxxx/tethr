import Foundation

/// カードから取り込んだ（テザーで保存した）カットの控え。
///
/// 保存先にファイルがあるかだけで判定すると、取り込んだ後で NAS などへ移したカットが「未取り込み」に戻り、
/// 二重に取り込んでしまう。カメラのシリアル・ファイル名・大きさ・撮影時刻の組で覚えておく
/// （ファイル番号は 9999 で一巡するので、名前だけでは足りない）
@MainActor
final class ImportLedger {
    private var keys: Set<String> = []

    private static let url: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Tethr", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("imported.json")
    }()

    init() {
        if let data = try? Data(contentsOf: Self.url),
           let saved = try? JSONDecoder().decode([String].self, from: data) {
            keys = Set(saved)
        }
    }

    private func key(serial: String, name: String, size: Int64, captured: Date?) -> String {
        "\(serial)|\(name)|\(size)|\(Int(captured?.timeIntervalSince1970 ?? 0))"
    }

    func contains(serial: String, name: String, size: Int64, captured: Date?) -> Bool {
        keys.contains(key(serial: serial, name: name, size: size, captured: captured))
    }

    func record(serial: String, name: String, size: Int64, captured: Date?) {
        guard keys.insert(key(serial: serial, name: name, size: size, captured: captured)).inserted else { return }
        do {
            try JSONEncoder().encode(Array(keys)).write(to: Self.url, options: .atomic)
        } catch {
            Log.write("取り込みの控えを保存できない: \(error.localizedDescription)")
        }
    }
}
