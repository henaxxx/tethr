import Foundation
import SwiftUI
import AppKit
import TethrKit

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
    /// セッションは開いたが、カードの下調べが終わるまで命令が通らない（電源を入れた直後）
    @Published private(set) var preparing = false
    @Published private(set) var shots: [Shot] = []
    /// カメラが申告した設定（現在値・選択肢・書き込めるか）
    @Published private(set) var props: [PTP.Prop: PropDesc] = [:]
    @Published private(set) var deviceInfo: DeviceInfo?
    @Published private(set) var lightMeter: Double?
    @Published private(set) var bufferRemaining: Int?
    @Published var selection: Shot.ID?
    @Published private(set) var busy = false
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
    @Published var deleteAfterDownload: Bool { didSet { save(); link.deleteAfterDownload = deleteAfterDownload } }
    /// シャッターの前に AF を走らせる（本体のシャッター全押しと同じ）
    @Published var autofocusBeforeShot: Bool { didSet { save() } }

    private let link = CameraLink()
    private var camera: PTPCamera? { link.camera }
    private var liveView: NikonLiveView?
    private var eventLoop: Task<Void, Never>?
    /// CheckEvent が使えない機種（Nikon 1）は、USB のイベントと露出計の直読みに切り替える
    private var checkEventUsable = true
    /// 撮影通知（ObjectAdded）を受けた回数。ライブビュー中の撮影で、撮り終えたかの目安にする
    private var shotNotifications = 0
    /// 設定を書き込んでいる数。その間はコマ取りと問い合わせを休む
    private var writing = 0
    private let thumbQueue = DispatchQueue(label: "app.tethr.thumb", qos: .userInitiated, attributes: .concurrent)
    private let frameQueue = DispatchQueue(label: "app.tethr.liveframe", qos: .userInitiated)

    // MARK: 初期化

    init() {
        let d = UserDefaults.standard
        let fallback = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Pictures/Tethr")
        baseDestination = d.string(forKey: "baseDestination").map { URL(fileURLWithPath: $0) } ?? fallback
        useDateSubfolder = d.bool(forKey: "useDateSubfolder")
        autoConnect = d.object(forKey: "autoConnect") as? Bool ?? true
        deleteAfterDownload = d.bool(forKey: "deleteAfterDownload")
        autofocusBeforeShot = d.object(forKey: "autofocusBeforeShot") as? Bool ?? true

        link.deleteAfterDownload = deleteAfterDownload
        applyDestination()

        link.onPhase = { [weak self] phase in self?.phaseChanged(phase) }
        link.onReady = { [weak self] camera in self?.cameraReady(camera) }
        link.onLost = { [weak self] reason in self?.cameraLost(reason) }
        link.onPTPEvent = { [weak self] event in self?.handle(event) }
        link.onFileSaved = { [weak self] url in self?.fileSaved(url) }
        link.onDownloadFailed = { [weak self] name, reason in
            guard let self else { return }
            self.failedTransfers.append(name)
            self.destinationProblem = reason
            self.lastError = String(localized: "「\(name)」を保存できませんでした。\n\(reason)\n\nカメラのカードには残っています。")
        }
    }

    private func save() {
        let d = UserDefaults.standard
        d.set(baseDestination.path, forKey: "baseDestination")
        d.set(useDateSubfolder, forKey: "useDateSubfolder")
        d.set(autoConnect, forKey: "autoConnect")
        d.set(deleteAfterDownload, forKey: "deleteAfterDownload")
        d.set(autofocusBeforeShot, forKey: "autofocusBeforeShot")
    }

    /// 日付サブフォルダ設定を反映した実際の保存先。
    var effectiveDestination: URL {
        guard useDateSubfolder else { return baseDestination }
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return baseDestination.appendingPathComponent(f.string(from: Date()))
    }

    private func applyDestination() {
        link.destination = effectiveDestination
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
        props[.batteryLevel].map { Int($0.current) }
    }

    /// レンズ名は PTP では取れない（libgphoto2 でも "Unknown value 00f5" だった）。
    /// 焦点距離の範囲と開放 F 値は読めるが、カメラの報告値は丸められていて実際のレンズ仕様と食い違うため出さない
    var lensDescription: String? { nil }

    var currentFocalLength: String? {
        props[.focalLength]?.currentText
    }

    /// シャッタースピードの設定。Nikon は正確な分数の独自プロパティを使う
    var shutterProp: PTP.Prop {
        (props[.nikonExposureTime]?.choices.isEmpty == false) ? .nikonExposureTime : .exposureTime
    }

    /// その項目をいま操作できるか。選択肢が取れていて、かつカメラが書き込めると言っていること。
    /// 露出モードで変わる（A ならシャッター、S なら絞りが固定される）
    func isWritable(_ prop: PTP.Prop) -> Bool {
        guard isConnected, let desc = props[prop] else { return false }
        return desc.writable && !desc.choices.isEmpty
    }

    /// 表示用の文字列で読み書きする（スクラバーやメニューは文字列の選択肢で動く）
    func textBinding(for prop: PTP.Prop) -> Binding<String> {
        Binding(
            get: { self.props[prop]?.currentText ?? "" },
            set: { text in
                guard let desc = self.props[prop],
                      let index = desc.choiceTexts.firstIndex(of: text) else { return }
                self.setProp(prop, to: desc.choices[index])
            }
        )
    }

    // MARK: 接続

    func connect() {
        lastError = nil
        failedTransfers = []
        applyDestination()
        link.open()
    }

    func disconnect() {
        Task {
            if let liveView, liveView.isActive { await liveView.stop(reason: "切断") }
            eventLoop?.cancel()
            link.close()
            clearCameraState()
            state = .disconnected
        }
    }

    private func phaseChanged(_ phase: CameraLink.Phase) {
        switch phase {
        case .closed:
            if case .connected = state { state = .disconnected }
            preparing = false
        case .searching:
            state = .failed(String(localized: "カメラが見つかりません。USB 接続と電源を確認してください。"))
            preparing = false
        case .opening:
            state = .connecting
            preparing = false
        case .preparing:
            state = .connecting
            preparing = true
        case .ready(let name):
            preparing = false
            state = .connected(name)
        }
    }

    private func cameraReady(_ camera: PTPCamera) {
        deviceInfo = camera.info
        checkEventUsable = camera.capabilities?.isNikon1 != true
        if camera.isNikon, camera.capabilities?.isNikon1 != true {
            let live = NikonLiveView(camera: camera, cameraIdentifier: camera.info?.serialNumber ?? "?")
            live.onChange = { [weak self] in self?.liveViewChanged() }
            live.onFrame = { [weak self] jpeg in self?.showFrame(jpeg) }
            live.shouldPauseFrames = { [weak self] in (self?.writing ?? 0) > 0 }
            liveView = live
        }
        clockOffset = link.clockDrift
        Task {
            await refreshAll()
            startEventLoop()
        }
    }

    private func cameraLost(_ reason: String?) {
        liveView?.forget()
        eventLoop?.cancel()
        clearCameraState()
        if let reason { state = .failed(reason) }
    }

    private func clearCameraState() {
        liveView = nil
        props = [:]
        deviceInfo = nil
        afState = .idle
        isLive = false
        busy = false
        clockOffset = nil
        liveFrame = nil
        liveFPS = 0
        frameTimes = []
        lightMeter = nil
        bufferRemaining = nil
        preparing = false
    }

    // MARK: 設定の読み書き

    private func refreshAll() async {
        guard let camera else { return }
        props = await camera.describeAll()
        await refreshCounters()
        let dump = props.keys.sorted { $0.rawValue < $1.rawValue }
            .map { "\($0.label)=\(props[$0]!.currentText)\(props[$0]!.writable ? "" : "🔒")" }
            .joined(separator: " ")
        Log.write("設定: \(dump)")
    }

    private func refreshCounters() async {
        guard let camera, camera.isNikon else { return }
        lightMeter = await camera.lightMeter()
        bufferRemaining = await camera.integer(PTPCamera.maximumShotsCode).map { Int($0) }
    }

    private func refresh(_ prop: PTP.Prop) async {
        guard let camera, let desc = await camera.describe(prop) else { return }
        props[prop] = desc
    }

    /// 本体側で変わった設定を読み直す（⌘R）
    func refreshSettings() {
        Task { await refreshAll() }
    }

    func setProp(_ prop: PTP.Prop, to value: Int64) {
        guard let camera, let desc = props[prop], value != desc.current else { return }
        writing += 1
        Task {
            defer { writing -= 1 }
            do {
                try await camera.write(desc, value: value)
                // 露出モードを変えると、書き込める項目がまとめて入れ替わる
                if prop == .exposureProgram { await refreshAll() } else { await refresh(prop) }
            } catch {
                // 露出モードの変更などでは、設定は通っているのに応答が遅れてエラーになることがある。
                // 失敗扱いにする前に読み直し、狙った値になっていれば成功とみなす（libgphoto2 版と同じ扱い）
                try? await Task.sleep(for: .milliseconds(400))
                await refresh(prop)
                if props[prop]?.current == value {
                    Log.write("  \(prop.label) の書き込み: エラー応答だが値は反映済み")
                } else {
                    lastError = String(localized: "\(prop.label) を変更できませんでした: \(error.localizedDescription)")
                }
            }
        }
    }

    // MARK: 本体側の変化

    /// 変化が続いている間は細かく、静かになったら間隔を空ける（iOS 版と同じ考え方）
    private func startEventLoop() {
        eventLoop?.cancel()
        eventLoop = Task { [weak self] in
            var quiet = 0
            while !Task.isCancelled {
                let interval: Duration = quiet > 12 ? .milliseconds(2000) : quiet > 4 ? .milliseconds(900) : .milliseconds(350)
                try? await Task.sleep(for: interval)
                guard let self, let camera = self.camera, self.isConnected else { return }
                // 撮影中、保存中、設定の書き込み中は叩かない
                if self.busy || self.writing > 0 || self.link.downloading > 0 { continue }
                let changed = await self.pollOnce(camera)
                quiet = changed ? 0 : quiet + 1
            }
        }
    }

    private func pollOnce(_ camera: PTPCamera) async -> Bool {
        guard checkEventUsable else {
            let before = lightMeter
            lightMeter = await camera.lightMeter()
            return before != lightMeter
        }
        let events: [PTPEvent]
        do {
            events = try await camera.checkEvent()
        } catch PTPError.response(0x2005) {
            checkEventUsable = false
            Log.write("CheckEvent 非対応。露出計を直接読む方式に切り替え")
            return false
        } catch {
            return false
        }
        let changed = Set(events.filter { $0.code == PTPEvent.devicePropChanged }.map { UInt16(truncatingIfNeeded: $0.param) })
        guard !changed.isEmpty else { return false }
        if changed.contains(UInt16(PTPCamera.lightMeterCode)) {
            lightMeter = await camera.lightMeter()
        }
        if changed.contains(UInt16(PTPCamera.maximumShotsCode)) {
            bufferRemaining = await camera.integer(PTPCamera.maximumShotsCode).map { Int($0) }
        }
        if changed.contains(PTP.Prop.exposureProgram.rawValue) {
            await refreshAll()
        } else {
            for prop in PTP.Prop.allCases where changed.contains(prop.rawValue) {
                await refresh(prop)
            }
        }
        return true
    }

    private func handle(_ event: PTPEvent) {
        switch event.code {
        case PTPEvent.objectAdded:
            shotNotifications += 1
        case PTPEvent.captureComplete:
            Task { await refreshCounters() }
        case PTPEvent.devicePropChanged where !checkEventUsable:
            if let prop = PTP.Prop(rawValue: UInt16(truncatingIfNeeded: event.param)) {
                Task { prop == .exposureProgram ? await refreshAll() : await refresh(prop) }
            }
        default:
            break
        }
    }

    // MARK: 操作

    /// 撮影通知を待つ上限。長秒時ノイズ低減では露光と同じ時間だけ処理が続くので、露光時間の 2 倍に余裕を足す
    private var captureWaitSeconds: Double {
        var exposure = 1.0
        if let value = props[.nikonExposureTime]?.current {
            let raw = UInt32(truncatingIfNeeded: value)
            if raw >= 0xFFFF_FFFD {
                exposure = 60
            } else if raw & 0xFFFF != 0 {
                exposure = Double(raw >> 16) / Double(raw & 0xFFFF)
            }
        }
        return 15 + exposure * 2
    }

    func shoot() {
        guard isConnected, !busy, let camera else { return }
        busy = true
        Task {
            defer { busy = false }
            let autofocus = autofocusBeforeShot
            let release: () async -> Bool = {
                if autofocus { _ = await camera.autofocus() }
                do {
                    try await camera.releaseShutter()
                    return true
                } catch {
                    self.lastError = String(localized: "撮影できませんでした: \(error.localizedDescription)")
                    return false
                }
            }
            if let liveView, liveView.state == .on {
                // ライブビューをいったん止め、記録先をカードに戻してから普段どおりに切る
                if let problem = await liveView.whileSuspended(shotCount: { self.shotNotifications },
                                                               waitSeconds: captureWaitSeconds, release) {
                    lastError = problem
                }
            } else {
                _ = await release()
            }
            await refreshCounters()
        }
    }

    /// ライブビューの切り替え。
    /// D300 はミラーアップしてシャッターを開いたまま保持するため、
    /// 点けっぱなしはセンサーの発熱とバッテリー消費につながる。
    func toggleLiveView() {
        guard isConnected else { return }
        guard let liveView else {
            lastError = String(localized: "この機種ではライブビューを使えません。")
            return
        }
        Task {
            if liveView.isActive {
                await liveView.stop(reason: "ボタン")
            } else if let problem = await liveView.start() {
                lastError = problem
            }
        }
    }

    private func liveViewChanged() {
        guard let liveView else { return }
        isLive = liveView.state != .off
        if liveView.state == .off {
            liveFrame = nil
            liveFPS = 0
            frameTimes = []
        }
    }

    /// JPEG の展開はメインスレッドの外で済ませる。表示が追いつかないうちは次のコマを積まない
    private var frameInFlight = false
    private func showFrame(_ jpeg: Data) {
        guard !frameInFlight else { return }
        frameInFlight = true
        frameQueue.async {
            let image = NSImage(data: jpeg)
            image?.cgImage(forProposedRect: nil, context: nil, hints: nil)   // ここで展開させる
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.frameInFlight = false
                guard self.isLive, let image else { return }
                self.liveFrame = image
                let now = Date()
                self.frameTimes.append(now)
                self.frameTimes.removeAll { now.timeIntervalSince($0) > 1 }
                self.liveFPS = self.frameTimes.count
            }
        }
    }

    /// カメラ本体に制御権を返す（上面液晶の PC 表示を解除する）。
    func releaseCameraControl() {
        guard isConnected, let camera else { return }
        Task {
            do {
                try await camera.send(.nikonChangeCameraMode, params: [0])
                Log.write("制御権を本体へ返却")
            } catch {
                lastError = error.localizedDescription
            }
        }
    }

    /// カメラの内蔵時計を Mac に合わせる。
    /// ずれたままだと撮影ファイルすべての EXIF 時刻が狂う。
    func syncClock() {
        guard isConnected, let camera else { return }
        Task {
            do {
                try await camera.setCameraClock(Date())
                clockOffset = 0
                Log.write("カメラ時計を Mac に合わせました")
            } catch {
                lastError = error.localizedDescription
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
        guard isConnected, afState != .running, let camera else { return }
        afState = .running
        Task {
            switch await camera.autofocus() {
            case true?: afState = .succeeded
            case false?: afState = .failed(String(localized: "ピントが合いませんでした"))
            case nil: afState = .failed(String(localized: "AF を実行できませんでした"))
            }
            await refreshCounters()
            // 結果表示は一時的なもの。少し見せてから消す。
            try? await Task.sleep(for: .seconds(2))
            if afState != .running { afState = .idle }
        }
    }

    /// AF 失敗時の詳細（ツールチップ用）
    var afFailureDetail: String? {
        if case .failed(let message) = afState { return message }
        return nil
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

    // MARK: 撮影ファイル

    private func fileSaved(_ url: URL) {
        let shot = Shot(url: url, arrived: Date())
        shots.insert(shot, at: 0)
        selection = shot.id
        loadThumbnail(for: shot.id, url: url)
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
