import Foundation
import ImageCaptureCore
import TethrKit
import UIKit

/// 動作を確かめていないカメラをつないだときの記録。配布版でも残す。
///
/// 開発環境の無いところで知らないカメラをつなぐことがあるので、何を名乗り、どの命令がどう返り、
/// 一覧や取り込みがどうなったかを、接続ごとに 1 つのファイルへ書く。
/// 確かめてある機種（`verifiedModels`）は、DeviceInfo で機種が分かった時点で記録をやめて捨てる。
///
/// - 入れないもの: カメラのシリアル番号と、それを含む ImageCaptureCore の UUID。位置情報
/// - 大きさ: 1 件 200KB まで、最新 20 件
/// - 端末の外に出るのは、利用者が「接続の記録」から共有したときだけ
@MainActor
final class CameraReporter: ObservableObject {

    /// 実機で確かめてある機種。これらは記録しない
    static let verifiedModels: Set<String> = ["D300"]
    /// 開発用。確かめてある機種でも記録する（基本モードを D300 で試すとき）
    static var recordVerified = false
    private static let maxBytes = 200_000
    private static let maxReports = 20

    static let directory: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CameraReports", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    /// 保存してある記録（新しい順）。一覧の画面が見る
    @Published private(set) var reports: [URL] = []

    /// 記録するかどうか。nil は機種が分かるまで保留（その間は手元に溜めておく）
    private var keeping: Bool?
    private var pending: [String] = []
    private var file: URL?
    private var bytes = 0
    private var truncated = false
    private var started = Date()
    /// 一覧に届いたファイルは多いので、最初の数件だけ詳しく書く
    private var filesNoted = 0
    private var thumbnailsNoted = 0

    private static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    init() {
        reload()
    }

    // MARK: 接続ごと

    /// カメラを見つけた。新しい記録を始める（機種が分かるまでは保留）
    func begin(_ device: ICCameraDevice) {
        finishQuietly()
        started = Date()
        filesNoted = 0
        thumbnailsNoted = 0
        let name = device.name ?? "?"
        if Self.verifiedModels.contains(name), !Self.recordVerified {
            keeping = false
            return
        }
        keeping = nil
        let info = Bundle.main.infoDictionary
        note("Tethr \(info?["CFBundleShortVersionString"] as? String ?? "?") (\(info?["CFBundleVersion"] as? String ?? "?"))"
             + "  iOS \(UIDevice.current.systemVersion)  \(Self.hardwareModel)")
        note("カメラを検出: \(name)  種類 \(device.productKind ?? "?")  接続 \(device.transportType ?? "?")")
        note("ImageCaptureCore の対応: \(device.capabilities.joined(separator: ", "))")
    }

    /// DeviceInfo を読んだ（読めなかった）。確かめてある機種なら記録をやめる
    func identified(_ info: DeviceInfo?, support: CameraCapabilities.Support?) {
        // 背面から戻って開き直したときにも呼ばれる。決めるのは 1 回だけ
        guard keeping == nil else { return }
        guard let info else {
            note("DeviceInfo を読めない")
            startKeeping(model: nil)
            return
        }
        if Self.verifiedModels.contains(info.model), !Self.recordVerified {
            keeping = false
            pending = []
            return
        }
        func hex(_ codes: [UInt16]) -> String { codes.map { String(format: "%04X", $0) }.joined(separator: " ") }
        note("DeviceInfo: \(info.manufacturer) / \(info.model) / ファームウェア \(info.version)")
        note(String(format: "  VendorExtensionID 0x%X → 読み方 0x%X、扱い %@", info.vendor, info.effectiveVendor, support?.rawValue ?? "?"))
        note("  命令: \(hex(info.operations))")
        note("  イベント: \(hex(info.events))")
        note("  設定項目: \(hex(info.properties))")
        startKeeping(model: info.model)
    }

    func note(_ text: String) {
        guard keeping != false else { return }
        let seconds = String(format: "%7.2f", Date().timeIntervalSince(started))
        let line = "\(Self.stamp.string(from: Date())) +\(seconds)s  \(text)\n"
        if keeping == nil {
            pending.append(line)
            // 機種が分からないまま長く続くときも、溜めすぎない
            if pending.count > 2000 { startKeeping(model: nil) }
            return
        }
        append(line)
    }

    /// 一覧に届いたファイル。最初の 5 件だけ詳しく残す
    func noteFiles(_ files: [ICCameraFile]) {
        guard keeping != false else { return }
        for file in files where filesNoted < 5 {
            filesNoted += 1
            note("一覧に届いた: \(file.name ?? "?")  \(file.fileSize) バイト  種類 \(file.uti ?? "?")  撮影 \(file.creationDate.map { "\($0)" } ?? "?")")
        }
    }

    /// サムネイルやプレビューの成否。失敗はすべて、成功は最初の 3 件だけ残す
    func noteThumbnail(_ name: String, ok: Bool, detail: String = "") {
        guard keeping != false else { return }
        if ok {
            guard thumbnailsNoted < 3 else { return }
            thumbnailsNoted += 1
        }
        note("\(ok ? "サムネイル" : "サムネイル失敗"): \(name) \(detail)")
    }

    /// 接続が終わった
    func end(_ reason: String) {
        guard keeping != false else { return }
        note("終わり: \(reason)")
        if keeping == nil { startKeeping(model: nil) }
        file = nil
        keeping = false
    }

    // MARK: 一覧の画面から

    func delete(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
        reload()
    }

    func deleteAll() {
        for url in reports where url != file { try? FileManager.default.removeItem(at: url) }
        reload()
    }

    // MARK: 書き出し

    private func startKeeping(model: String?) {
        keeping = true
        let format = DateFormatter()
        format.dateFormat = "yyyyMMdd-HHmmss"
        format.locale = Locale(identifier: "en_US_POSIX")
        let safeModel = (model ?? "unknown").components(separatedBy: CharacterSet.alphanumerics.inverted).joined(separator: "_")
        let url = Self.directory.appendingPathComponent("\(format.string(from: started)) \(safeModel).txt")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        file = url
        bytes = 0
        truncated = false
        let lines = pending
        pending = []
        for line in lines { append(line) }
        trimOld()
        reload()
    }

    private func append(_ line: String) {
        guard let file, !truncated else { return }
        var data = Data(line.utf8)
        if bytes + data.count > Self.maxBytes {
            data = Data("（記録が上限に達したので、ここまで）\n".utf8)
            truncated = true
        }
        guard let handle = try? FileHandle(forWritingTo: file) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: data)
        bytes += data.count
    }

    private func finishQuietly() {
        if keeping == true, file != nil { note("（次のカメラの記録に移る）") }
        file = nil
        pending = []
        keeping = nil
    }

    private func trimOld() {
        let files = listReports()
        for url in files.dropFirst(Self.maxReports) { try? FileManager.default.removeItem(at: url) }
    }

    private func reload() {
        reports = listReports()
    }

    private func listReports() -> [URL] {
        let fm = FileManager.default
        let files = (try? fm.contentsOfDirectory(at: Self.directory, includingPropertiesForKeys: [.creationDateKey])) ?? []
        return files.filter { $0.pathExtension == "txt" }.sorted { $0.lastPathComponent > $1.lastPathComponent }
    }

    /// iPhone16,1 のような機種の識別
    private static var hardwareModel: String {
        var info = utsname()
        uname(&info)
        return withUnsafeBytes(of: &info.machine) { raw in
            String(decoding: raw.prefix(while: { $0 != 0 }), as: UTF8.self)
        }
    }
}
