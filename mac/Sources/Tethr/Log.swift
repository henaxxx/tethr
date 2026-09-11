import Foundation

/// ~/Library/Logs/Tethr.log に追記する。
/// GUI アプリは stdout が見えないため、接続まわりの診断はここに残す。
enum Log {
    static let url: URL = {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("Tethr.log")
    }()

    private static let queue = DispatchQueue(label: "app.tethr.log")
    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    static func write(_ message: String) {
        let line = "[\(formatter.string(from: Date()))] \(message)\n"
        queue.async {
            guard let data = line.data(using: .utf8) else { return }
            if let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            } else {
                try? data.write(to: url)
            }
        }
    }

    static func startSession() {
        let header = """

        ================================================================
        Tethr 起動  \(Date())
        ================================================================
        """
        write(header)
    }
}
