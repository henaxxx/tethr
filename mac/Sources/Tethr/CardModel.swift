import Foundation
import AppKit
import ImageCaptureCore
import TethrKit

/// カード上の 1 カット
struct CardItem: Identifiable, Equatable {
    /// フォルダ名/ファイル名（別のフォルダに同じ名前があり得る）
    let id: String
    let name: String
    let file: ICCameraFile
    let size: Int64
    let captured: Date?
    var thumbnail: NSImage?
    /// 取り込み済み（控えにあるか、保存先に同じ名前・大きさのファイルがある）
    var imported: Bool
    /// iPhone の記録から位置を付けられる見込みがある
    var locatable: Bool

    static func == (a: CardItem, b: CardItem) -> Bool {
        a.id == b.id && a.thumbnail === b.thumbnail && a.imported == b.imported && a.locatable == b.locatable
    }
}

/// カードの中身を見て、選んだカットやまだ取り込んでいないカットを保存先へ落とす。
/// 落としたあと、iPhone から受け取った位置情報があれば続けて書き込む
@MainActor
final class CardModel: ObservableObject {

    enum ImportPhase: Equatable {
        case downloading(done: Int, total: Int)
        case geotagging(count: Int)
    }

    /// カードを見ている（テザーの一覧ではなく）
    @Published var active = false
    @Published private(set) var items: [CardItem] = []
    @Published var selection: Set<String> = []
    /// 大きく表示しているカット
    @Published var focus: String?
    @Published private(set) var preview: NSImage?
    /// 一覧がまだ出そろっていない
    @Published private(set) var loading = false
    /// 接続時に数えたカード内のオブジェクト数（読み込み中の分母）
    @Published private(set) var expected: Int?
    @Published private(set) var importPhase: ImportPhase?
    @Published private(set) var lastSummary: String?
    /// 取り込んだあと、iPhone の記録から位置を書き込む
    @Published var writeLocations: Bool {
        didSet { UserDefaults.standard.set(writeLocations, forKey: "cardWriteLocations") }
    }

    private let link: CameraLink
    private let geo: GeoStore
    private let ledger: ImportLedger
    /// 撮影日に応じた保存先（日付フォルダの設定を反映する）
    var destination: (Date) -> URL = { _ in FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Pictures/Tethr") }
    /// 取り込みの控えに使うカメラの識別（シリアル番号）
    var serial: () -> String = { "?" }
    /// 取り終えた・取りに行っているサムネイル
    private var thumbnailRequested: Set<String> = []
    /// 取りに行く順番待ち。画面に出た順に 1 枚ずつ取る
    private var thumbnailQueue: [String] = []
    private var thumbnailWorker: Task<Void, Never>?
    private var anchor: String?
    private var previewTask: Task<Void, Never>?

    init(link: CameraLink, geo: GeoStore, ledger: ImportLedger) {
        self.link = link
        self.geo = geo
        self.ledger = ledger
        writeLocations = UserDefaults.standard.object(forKey: "cardWriteLocations") as? Bool ?? true
    }

    var unimported: [CardItem] { items.filter { !$0.imported } }
    var locatableCount: Int { items.filter(\.locatable).count }
    var importing: Bool { importPhase != nil }

    // MARK: 一覧

    /// カメラから届いたファイルで一覧を作り直す。サムネイルは持ち越す
    func refresh() {
        let files = link.cardFiles
        let wasLoading = loading
        loading = !link.cardSettled
        expected = link.cardExpected
        guard !files.isEmpty else {
            if !items.isEmpty { reset() }
            return
        }
        let writer = geo.payload.map { GeoWriter(payload: $0) }
        let known = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
        let serial = serial()
        items = files.map { key, file in
            let name = file.name ?? "?"
            let size = Int64(file.fileSize)
            let captured = file.creationDate
            let imported = ledger.contains(serial: serial, name: name, size: size, captured: captured)
                || existsInDestination(name: name, size: size, captured: captured)
            return CardItem(id: key, name: name, file: file, size: size, captured: captured,
                            thumbnail: known[name]?.thumbnail, imported: imported,
                            locatable: writer?.canLocate(name: name, captured: captured) ?? false)
        }
        .sorted { ($0.captured ?? .distantPast, $0.id) > ($1.captured ?? .distantPast, $1.id) }
        selection = selection.filter { name in items.contains { $0.id == name } }
        // 読み込み中に画面に出ていたカットのサムネイルを、出そろったところで取りに行く
        if wasLoading && !loading { runThumbnailQueue() }
    }

    /// 受け取った位置情報が変わったら、付けられるかどうかだけ付け直す
    func geoChanged() {
        let writer = geo.payload.map { GeoWriter(payload: $0) }
        for i in items.indices {
            items[i].locatable = writer?.canLocate(name: items[i].name, captured: items[i].captured) ?? false
        }
    }

    func reset() {
        items = []
        selection = []
        focus = nil
        preview = nil
        thumbnailRequested = []
        thumbnailQueue = []
        thumbnailWorker?.cancel()
        thumbnailWorker = nil
        loading = false
        expected = nil
    }

    private func existsInDestination(name: String, size: Int64, captured: Date?) -> Bool {
        let url = destination(captured ?? Date()).appendingPathComponent(name)
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let existing = attributes[.size] as? Int64 else { return false }
        return existing == size
    }

    // MARK: サムネイルとプレビュー

    /// 画面に出てきたカットだけ、1 枚ずつ取りに行く。縦位置のカットは向きを読んで回す。
    ///
    /// カメラとのやり取りは 1 本の管を順番に使う。一覧の読み込み中にサムネイルを取りに行くと、
    /// macOS がカードを 1 件ずつ問い合わせている間に割り込んで、読み込みそのものが遅くなった。
    /// 出そろうまでは順番待ちに積むだけにする
    func requestThumbnail(for id: String) {
        guard !thumbnailRequested.contains(id), !thumbnailQueue.contains(id) else { return }
        thumbnailQueue.append(id)
        if !loading { runThumbnailQueue() }
    }

    /// スクロールで画面から消えた。まだ取りに行っていなければ取り消す
    func cancelThumbnail(for id: String) {
        thumbnailQueue.removeAll { $0 == id }
    }

    private func runThumbnailQueue() {
        guard thumbnailWorker == nil, !thumbnailQueue.isEmpty else { return }
        thumbnailWorker = Task {
            defer { thumbnailWorker = nil }
            while !Task.isCancelled, !loading, !thumbnailQueue.isEmpty {
                // 取り込み中は保存を優先する
                if importing {
                    try? await Task.sleep(for: .milliseconds(300))
                    continue
                }
                let id = thumbnailQueue.removeFirst()
                guard !thumbnailRequested.contains(id), let file = items.first(where: { $0.id == id })?.file else { continue }
                thumbnailRequested.insert(id)
                let started = Date()
                guard let data = await CardFile.thumbnailData(file) else { continue }
                let fetched = Date()
                var orientation: Int?
                if let probe = NSImage(data: data), probe.size.width > probe.size.height {
                    orientation = await CardFile.orientation(file)
                }
                #if DEBUG
                if thumbnailRequested.count <= 5 {
                    Log.write(String(format: "サムネイル %@: %d バイト %.2f 秒、向きの読み取り %.2f 秒", id, data.count,
                                     fetched.timeIntervalSince(started), Date().timeIntervalSince(fetched)))
                }
                #endif
                guard let image = OrientedImage.make(data, orientation: orientation),
                      let i = items.firstIndex(where: { $0.id == id }) else { continue }
                items[i].thumbnail = image
            }
        }
    }

    /// 1 枚を大きく見る。NEF に埋め込まれた原寸の JPEG だけを読む
    func open(_ id: String) {
        focus = id
        preview = nil
        previewTask?.cancel()
        guard let file = items.first(where: { $0.id == id })?.file else { return }
        previewTask = Task {
            let loaded = await CardFile.embeddedPreview(file)
            guard !Task.isCancelled, focus == id else { return }
            if let loaded {
                preview = OrientedImage.make(loaded.jpeg, orientation: loaded.orientation, maxPixel: 3000)
            } else if let data = await CardFile.thumbnailData(file, maxPixel: 2400) {
                preview = NSImage(data: data)
            }
        }
    }

    func close() {
        previewTask?.cancel()
        focus = nil
        preview = nil
    }

    func step(_ delta: Int) {
        guard let focus, let i = items.firstIndex(where: { $0.id == focus }) else { return }
        let next = i + delta
        guard items.indices.contains(next) else { return }
        selection = [items[next].id]
        anchor = items[next].id
        open(items[next].id)
    }

    // MARK: 選択

    /// クリック（⌘ で足し引き、⇧ で範囲）
    func click(_ id: String) {
        let flags = NSEvent.modifierFlags
        if flags.contains(.command) {
            if selection.contains(id) { selection.remove(id) } else { selection.insert(id) }
            anchor = id
        } else if flags.contains(.shift), let anchor,
                  let a = items.firstIndex(where: { $0.id == anchor }),
                  let b = items.firstIndex(where: { $0.id == id }) {
            selection = Set(items[min(a, b)...max(a, b)].map(\.id))
        } else {
            selection = [id]
            anchor = id
        }
    }

    // MARK: 取り込み

    func importSelected() {
        startImport(items.filter { selection.contains($0.id) && !$0.imported })
    }

    func importAllRemaining() {
        startImport(unimported)
    }

    private func startImport(_ targets: [CardItem]) {
        guard !targets.isEmpty, !importing else { return }
        lastSummary = nil
        Task { await runImport(targets) }
    }

    private func runImport(_ targets: [CardItem]) async {
        // 撮影順に落とす（保存先のファイルの並びと、書き込みのログが追いやすい）
        let ordered = targets.sorted { ($0.captured ?? .distantPast) < ($1.captured ?? .distantPast) }
        Log.write("カードから取り込み: \(ordered.count) 件")
        importPhase = .downloading(done: 0, total: ordered.count)
        let serial = serial()
        var saved: [URL] = []
        var failures: [String] = []
        for (n, item) in ordered.enumerated() {
            let directory = destination(item.captured ?? Date())
            // カードからは消さない。取り込みの確かさを確かめられるまでは、利用者が自分で消す
            switch await link.download(item.file, into: directory) {
            case .success(let url):
                saved.append(url)
                ledger.record(serial: serial, name: item.name, size: item.size, captured: item.captured)
                if let i = items.firstIndex(where: { $0.id == item.id }) { items[i].imported = true }
            case .failure(let failure):
                failures.append(item.name)
                Log.write("取り込み失敗 \(item.name): \(failure.message)")
            }
            importPhase = .downloading(done: n + 1, total: ordered.count)
        }

        var located = 0
        if writeLocations, let payload = geo.payload, !saved.isEmpty {
            let writer = GeoWriter(payload: payload)
            let matches = saved.compactMap { writer.match($0) }
            if !matches.isEmpty {
                importPhase = .geotagging(count: matches.count)
                // exiftool は同期的に時間がかかるので、主スレッドの外で走らせる
                let report = await Task.detached(priority: .userInitiated) { writer.apply(matches) { _, _ in } }.value
                located = report.written.count
                for failed in report.failed {
                    Log.write("位置を書き込めない \(failed.name): \(failed.reason)")
                }
            }
        }

        importPhase = nil
        var summary = String(localized: "\(saved.count) 枚を取り込みました")
        if writeLocations, geo.payload != nil, !saved.isEmpty {
            summary += String(localized: "（位置を書き込んだのは \(located) 枚）")
        }
        if !failures.isEmpty {
            summary += String(localized: "。\(failures.count) 枚は取り込めませんでした（\(failures.prefix(3).joined(separator: ", "))）")
        }
        lastSummary = summary
        Log.write(summary)
    }
}
