import Foundation

/// 開発版だけで動く記録。実機での振る舞いを Mac から devicectl で吸い出して確かめるため。
/// 製品版では何もしない。
enum DebugLog {
    #if DEBUG
    private static let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("debug.log")
    private static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    static func write(_ text: @autoclosure () -> String) {
        let line = "\(stamp.string(from: Date())) \(text())\n"
        if let h = try? FileHandle(forWritingTo: url) {
            h.seekToEndOfFile()
            h.write(Data(line.utf8))
            try? h.close()
        } else {
            try? Data(line.utf8).write(to: url)
        }
    }
    #else
    static func write(_ text: @autoclosure () -> String) {}
    #endif
}
