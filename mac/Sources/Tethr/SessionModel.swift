import Foundation
import SwiftUI
import AppKit

enum AFState: Equatable {
    case idle
    case running
    case succeeded
    case failed(String)
}

enum ConnectionState: Equatable {
    case disconnected
    case connecting
    case connected(String)
    case failed(String)
}

@MainActor
final class SessionModel: ObservableObject {

    // MARK: 状態

    @Published private(set) var state: ConnectionState = .disconnected
    @Published private(set) var shots: [Shot] = []
    @Published private(set) var settings: [String: String] = [:]
    @Published private(set) var deviceInfo: [String: String] = [:]
    @Published private(set) var choices: [String: [String]] = [:]
    /// カメラが今この瞬間「書き込み不可」と申告している項目。
    /// 露出モードで変わる（A なら shutterspeed、S なら f-number が固定される）。
    @Published private(set) var readonlyKeys: Set<String> = []
    @Published private(set) var lightMeter: Double?
    @Published private(set) var bufferRemaining: Int?
    @Published var selection: Shot.ID?
    @Published var busy = false
    @Published private(set) var afState: AFState = .idle
    @Published private(set) var isLive = false
    @Published private(set) var liveFrame: NSImage?
    @Published private(set) var liveFPS: Int = 0
    /// 接続時点で測った、カメラ時計と Mac の時刻差（秒）。正ならカメラが遅れている。
    @Published private(set) var clockOffset: TimeInterval?
    private var frameTimes: [Date] = []
    @Published var lastError: String?
    /// 転送に失敗したコマ。カード側には残っているので取り直せる。
    @Published private(set) var failedTransfers: [String] = []
    /// 保存先そのものに問題があるとき、その説明
    @Published private(set) var destinationProblem: String?

    /// 拡大表示用のフル解像度プレビュー（選択中の 1 枚だけ保持する）
    @Published private(set) var fullPreview: NSImage?
    private var fullPreviewID: Shot.ID?

    // MARK: 設定（UserDefaults に永続化）

    @Published var baseDestination: URL { didSet { save(); applyDestination() } }
    @Published var useDateSubfolder: Bool { didSet { save(); applyDestination() } }
    @Published var autoConnect: Bool { didSet { save() } }
    @Published var deleteAfterDownload: Bool { didSet { save(); engine.deleteAfterDownload = deleteAfterDownload } }

    // MARK: 読み書きするカメラ設定のキー

    static let dialKeys = ["shutterspeed", "f-number", "iso"]
    static let menuKeys = ["whitebalance", "imagequality"]
    static let editableKeys = dialKeys + menuKeys
    static let liveKeys = editableKeys + ["expprogram", "batterylevel", "focallength",
                                          "exposurecompensation", "focusmode", "autofocus"]
    /// 選択肢を読むキー。露出モードと AF 設定もここに含める。
    static let choiceKeys = editableKeys + ["expprogram", "autofocus"]
    static let deviceKeys = ["serialnumber", "deviceversion", "lensname", "datetime"]

    private let engine = CameraEngine()
    private let thumbQueue = DispatchQueue(label: "app.tethr.thumb", qos: .userInitiated, attributes: .concurrent)

    // MARK: 初期化

    init() {
        let d = UserDefaults.standard
        let fallback = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Pictures/Tethr")
        baseDestination = d.string(forKey: "baseDestination").map { URL(fileURLWithPath: $0) } ?? fallback
        useDateSubfolder = d.bool(forKey: "useDateSubfolder")
        autoConnect = d.object(forKey: "autoConnect") as? Bool ?? true
        deleteAfterDownload = d.bool(forKey: "deleteAfterDownload")

        engine.deleteAfterDownload = deleteAfterDownload
        applyDestination()

        engine.onEvent = { [weak self] event in
            Task { @MainActor in self?.handle(event) }
        }
    }

    private func save() {
        let d = UserDefaults.standard
        d.set(baseDestination.path, forKey: "baseDestination")
        d.set(useDateSubfolder, forKey: "useDateSubfolder")
        d.set(autoConnect, forKey: "autoConnect")
        d.set(deleteAfterDownload, forKey: "deleteAfterDownload")
    }

    /// 日付サブフォルダ設定を反映した実際の保存先。
    var effectiveDestination: URL {
        guard useDateSubfolder else { return baseDestination }
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return baseDestination.appendingPathComponent(f.string(from: Date()))
    }

    private func applyDestination() {
        engine.destination = effectiveDestination
        destinationProblem = checkDestination()
    }

    /// 保存先が実際に書けるか確かめる。
    /// 外付けドライブを指定している場合、取り外しやスリープで
    /// 書けなくなることがある。撮ってから気づくのでは遅い。
    @discardableResult
    func checkDestination() -> String? {
        let fm = FileManager.default
        let dir = effectiveDestination
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            return String(localized: "保存先を作成できません: \(dir.path)")
        }
        let probe = dir.appendingPathComponent(".tethr-write-test")
        do {
            try Data([0]).write(to: probe)
            try? fm.removeItem(at: probe)
        } catch {
            return String(localized: "保存先に書き込めません: \(dir.path)")
        }
        return nil
    }

    func clearFailedTransfers() {
        failedTransfers = []
        destinationProblem = checkDestination()
    }

    // MARK: 派生情報

    var isConnected: Bool {
        if case .connected = state { return true }
        return false
    }

    var modelName: String {
        if case .connected(let m) = state { return m }
        return String(localized: "未接続")
    }

    var batteryPercent: Int? {
        Format.number(settings["batterylevel"]).map { Int($0) }
    }

    /// レンズ名。カメラが正式名称を返すときだけ表示する。
    /// サードパーティ製レンズでは "Unknown value 00f5" のような
    /// 識別子しか返らない。焦点距離と開放F値から組み立てることもできるが、
    /// カメラの報告値は丸められていて実際のレンズ仕様と食い違うため出さない。
    var lensDescription: String? {
        let raw = deviceInfo["lensname"] ?? ""
        guard !raw.isEmpty, !raw.lowercased().hasPrefix("unknown") else { return nil }
        return raw
    }

    var currentFocalLength: String? {
        settings["focallength"].map { Format.focal($0) }
    }

    // MARK: 接続

    func connect() {
        guard !isConnected, state != .connecting else { return }
        state = .connecting
        lastError = nil
        failedTransfers = []
        applyDestination()
        engine.connect { [weak self] result in
            Task { @MainActor in
                guard let self else { return }
                switch result {
                case .success(let model):
                    self.state = .connected(model)
                    Log.write("保存先: \(self.effectiveDestination.path)")
                    self.refreshSettings()
                    self.refreshDeviceInfo()
                    self.refreshChoices()
                case .failure(let error):
                    self.state = .failed(error.localizedDescription)
                }
            }
        }
    }

    func disconnect() {
        engine.disconnect()
        state = .disconnected
        settings = [:]
        deviceInfo = [:]
        choices = [:]
        readonlyKeys = []
        afState = .idle
        isLive = false
        clockOffset = nil
        liveFrame = nil
        liveFPS = 0
        frameTimes = []
        lightMeter = nil
        bufferRemaining = nil
    }

    // MARK: 操作

    func shoot() {
        guard isConnected, !busy else { return }
        busy = true
        engine.triggerCapture { [weak self] error in
            Task { @MainActor in
                guard let self else { return }
                self.busy = false
                if let error { self.lastError = error.localizedDescription }
            }
        }
    }

    /// ライブビューの切り替え。
    /// D300 はミラーアップしてシャッターを開いたまま保持するため、
    /// 点けっぱなしはセンサーの発熱とバッテリー消費につながる。
    func toggleLiveView() {
        guard isConnected else { return }
        let turnOn = !isLive
        engine.setLiveView(turnOn) { [weak self] error in
            Task { @MainActor in
                guard let self else { return }
                if let error {
                    self.lastError = error.localizedDescription
                    return
                }
                self.isLive = turnOn
                if !turnOn {
                    self.liveFrame = nil
                    self.liveFPS = 0
                    self.frameTimes = []
                }
            }
        }
    }

    /// カメラ本体に制御権を返す（上面液晶の PC 表示を解除する）。
    func releaseCameraControl() {
        guard isConnected else { return }
        engine.releaseCameraControl { [weak self] error in
            Task { @MainActor in
                if let error { self?.lastError = error.localizedDescription }
            }
        }
    }

    /// カメラの内蔵時計を Mac に合わせる。
    /// ずれたままだと撮影ファイルすべての EXIF 時刻が狂う。
    func syncClock() {
        guard isConnected else { return }
        let now = Int(Date().timeIntervalSince1970)
        engine.writeConfig("datetime", value: String(now)) { [weak self] error in
            Task { @MainActor in
                guard let self else { return }
                if let error {
                    self.lastError = error.localizedDescription
                } else {
                    self.clockOffset = 0
                    Log.write("カメラ時計を Mac に合わせました")
                }
            }
        }
    }

    /// 時計のずれを読める形にする
    var clockOffsetDescription: String? {
        guard let offset = clockOffset else { return nil }
        let seconds = Int(offset.rounded())
        if abs(seconds) < 60 {
            if seconds == 0 { return String(localized: "一致") }
            return seconds > 0 ? String(localized: "\(abs(seconds))秒遅れ")
                               : String(localized: "\(abs(seconds))秒進み")
        }
        let m = abs(seconds) / 60 % 60
        let h = abs(seconds) / 3600
        let body = h > 0 ? String(localized: "\(h)時間\(m)分") : String(localized: "\(m)分")
        return seconds > 0 ? String(localized: "\(body)遅れ") : String(localized: "\(body)進み")
    }

    /// AF を走らせる。シャッター半押しに相当。
    func autofocus() {
        guard isConnected, afState != .running else { return }
        afState = .running
        engine.driveAutofocus { [weak self] error in
            Task { @MainActor in
                guard let self else { return }
                if let error {
                    self.afState = .failed(error.localizedDescription)
                } else {
                    self.afState = .succeeded
                }
                self.refreshSettings()
                // 結果表示は一時的なもの。少し見せてから消す。
                try? await Task.sleep(for: .seconds(2))
                if self.afState != .running { self.afState = .idle }
            }
        }
    }

    /// AF 失敗時の詳細（ツールチップ用）
    var afFailureDetail: String? {
        if case .failed(let message) = afState { return message }
        return nil
    }

    /// シャッター時にカメラが AF を行うか
    var autofocusOnCapture: Binding<Bool> {
        Binding(
            get: { self.settings["autofocus"] == "On" },
            set: { self.setSetting("autofocus", to: $0 ? "On" : "Off") }
        )
    }

    func refreshSettings() {
        guard isConnected else { return }
        engine.readConfig(Self.liveKeys) { [weak self] cfg, readonly in
            Task { @MainActor in
                self?.settings.merge(cfg) { _, new in new }
                self?.readonlyKeys = readonly
            }
        }
    }

    private func refreshDeviceInfo() {
        engine.readConfig(Self.deviceKeys) { [weak self] cfg, _ in
            Task { @MainActor in
                self?.deviceInfo = cfg
                // 時計のずれは読んだ瞬間に確定させる。あとで計算すると
                // 経過時間ぶんだけ誤差が乗る。
                if let raw = cfg["datetime"], let epoch = Double(raw) {
                    self?.clockOffset = Date().timeIntervalSince1970 - epoch
                }
                let dump = Self.deviceKeys.map { "\($0)=\(cfg[$0] ?? "―")" }.joined(separator: " ")
                Log.write("機器情報: \(dump)")
                if let lens = self?.lensDescription { Log.write("レンズ表記: \(lens)") }
            }
        }
    }

    private func refreshChoices() {
        engine.readChoices(Self.choiceKeys) { [weak self] ch in
            Task { @MainActor in
                self?.choices = ch
                // 選択肢が取れないとダイヤルは無効表示になる。
                // 撮影モードによっては絞りやシャッターが固定される点に注意。
                let dump = Self.choiceKeys.map { "\($0)=\(ch[$0]?.count ?? 0)" }.joined(separator: " ")
                Log.write("選択肢の件数: \(dump)")
                for key in Self.dialKeys {
                    guard let list = ch[key], !list.isEmpty else { continue }
                    Log.write("  \(key) 先頭: \(list.prefix(6).joined(separator: " | "))")
                }
            }
        }
    }

    func setSetting(_ key: String, to value: String) {
        guard isConnected else { return }
        let previous = settings[key]
        settings[key] = value
        engine.writeConfig(key, value: value) { [weak self] error in
            Task { @MainActor in
                guard let self else { return }
                if let error {
                    self.settings[key] = previous
                    self.lastError = error.localizedDescription
                } else {
                    self.refreshSettings()
                    // 露出モードを変えると、変更できる項目そのものが入れ替わる
                    if key == "expprogram" { self.refreshChoices() }
                }
            }
        }
    }

    /// その項目をいま操作できるか。
    /// 選択肢が取れていて、かつカメラが読み取り専用と言っていないこと。
    func isWritable(_ key: String) -> Bool {
        isConnected && !(choices[key] ?? []).isEmpty && !readonlyKeys.contains(key)
    }

    func binding(for key: String) -> Binding<String> {
        Binding(
            get: { self.settings[key] ?? "" },
            set: { self.setSetting(key, to: $0) }
        )
    }

    func revealInFinder(_ shot: Shot) {
        NSWorkspace.shared.activateFileViewerSelecting([shot.url])
    }

    // MARK: 拡大用プレビュー

    /// 選択が変わったらフル解像度プレビューを読み直す。
    /// NEF には元画像と同じ 4288×2848 の JPEG が埋まっているので、
    /// RAW をデコードせずに等倍表示まで賄える。
    func loadFullPreview(for id: Shot.ID?) {
        guard let id, let shot = shots.first(where: { $0.id == id }) else {
            fullPreview = nil
            fullPreviewID = nil
            return
        }
        guard fullPreviewID != id else { return }
        fullPreviewID = id
        fullPreview = nil
        let url = shot.url
        thumbQueue.async {
            guard let (image, _) = Thumbnailer.load(url, maxPixel: 4288) else { return }
            Task { @MainActor [weak self] in
                guard let self, self.fullPreviewID == id else { return }
                self.fullPreview = image
            }
        }
    }

    // MARK: イベント処理

    private func handle(_ event: CameraEvent) {
        switch event {
        case .fileArrived(let url):
            let shot = Shot(url: url, arrived: Date())
            shots.insert(shot, at: 0)
            selection = shot.id
            loadThumbnail(for: shot.id, url: url)
            refreshSettings()

        case .property(let key, let value):
            switch key {
            case "lightmeter":
                lightMeter = Double(value).map { $0 / 6.0 }
            case "maximumshots":
                bufferRemaining = Double(value).map { Int($0) }
            default:
                if Self.liveKeys.contains(key) { settings[key] = value }
                if Self.deviceKeys.contains(key) { deviceInfo[key] = value }
            }

        case .downloadFailed(let name, let reason):
            failedTransfers.append(name)
            destinationProblem = reason
            lastError = String(localized: "「\(name)」を保存できませんでした。\n\(reason)\n\nカメラのカードには残っています。")

        case .previewFrame(let image):
            liveFrame = image
            let now = Date()
            frameTimes.append(now)
            frameTimes.removeAll { now.timeIntervalSince($0) > 1 }
            liveFPS = frameTimes.count

        case .captureComplete:
            busy = false

        case .disconnected(let why):
            state = .failed(why)
        }
    }

    private func loadThumbnail(for id: Shot.ID, url: URL) {
        thumbQueue.async {
            guard let (image, meta) = Thumbnailer.load(url, maxPixel: 1200) else { return }
            Task { @MainActor [weak self] in
                guard let self, let i = self.shots.firstIndex(where: { $0.id == id }) else { return }
                self.shots[i].thumbnail = image
                self.shots[i].meta = meta
                if self.selection == id { self.loadFullPreview(for: id) }
            }
        }
    }
}
