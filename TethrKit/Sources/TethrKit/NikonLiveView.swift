import Foundation

/// Nikon のライブビューを生の PTP 命令で動かす。画面の作りはアプリ側に任せ、ここは手順だけを持つ。
///
/// 手順は libgphoto2（library.c）と同じで、D300 の実機で iOS・Mac とも 640×426・25〜27fps を確認している:
///   ChangeCameraMode(1) → 必要なら記録先を SDRAM に → StartLiveView → DeviceReady を待つ → GetLiveViewImg を繰り返す
///
/// 気をつけること（どれも実機で確かめた、または libgphoto2 のソースにある）
/// - カードの読み込みが終わるまでは、開始が OK でも映像が返らない（NotLiveView）
/// - D300 は記録先がカードのままだと開始を拒否する（禁止条件 0x00000001）。SDRAM に切り替えると通る
/// - 記録先を SDRAM にしたまま撮るとカードに残らない。撮るときはライブビューをいったん止めてカードへ戻す
///   （ライブビューを付けたまま記録先だけ戻して切ったら、シャッター音が 3 回鳴って画像が届かず、
///    以後ライブビューが開始できなくなった）
/// - 止める命令を省くとミラーが上がったまま残る
/// - レリーズモードダイヤルが Lv だとカメラが開始を拒否する
@MainActor
public final class NikonLiveView {

    public enum State: Equatable { case off, starting, on, stopping }

    public private(set) var state: State = .off {
        didSet { if state != oldValue { onChange?() } }
    }
    /// 撮影のために一時的に止めている。映像は最後のコマのまま
    public private(set) var suspended = false {
        didSet { if suspended != oldValue { onChange?() } }
    }

    /// 状態が変わった
    public var onChange: (() -> Void)?
    /// 1 コマ届いた（独自ヘッダを外した JPEG）
    public var onFrame: ((Data) -> Void)?
    /// 設定の書き込み中などで、コマ取りを休むべきか
    public var shouldPauseFrames: () -> Bool = { false }

    private let camera: PTPCamera
    /// カードのままで映像が来なかったカメラを覚えておく鍵
    private let rememberKey: String
    private var loop: Task<Void, Never>?
    private var tookControl = false
    /// こちらで記録先を SDRAM に切り替えた。止めるときにカードへ戻す
    private var switchedToSDRAM = false
    /// 撮影などで一時的にコマ取りを止めている数
    private var pauseCount = 0
    /// 開始処理の途中で止めるよう頼まれた
    private var stopRequested = false

    public static let recordingMedia: UInt32 = 0xD10B        // 0 = カード, 1 = SDRAM
    public static let liveViewStatus: UInt32 = 0xD1A2
    public static let prohibitCondition: UInt32 = 0xD1A4

    public init(camera: PTPCamera, cameraIdentifier: String) {
        self.camera = camera
        self.rememberKey = "liveViewNeedsSDRAM.\(cameraIdentifier)"
    }

    public var isActive: Bool { state != .off }

    private func log(_ text: String) { camera.log(text) }

    // MARK: 開始

    /// 開始する。できなければ利用者向けの説明を返す
    public func start() async -> String? {
        guard state == .off else { return nil }
        state = .starting
        stopRequested = false
        log("ライブビュー: 開始 \(await cameraState())")

        do {
            // 制御権をホストへ。ChangeCameraModeFailed は libgphoto2 も無視して進む
            do {
                try await camera.send(.nikonChangeCameraMode, params: [1])
            } catch PTPError.response(0xA003) {
                log("ライブビュー: 制御権 ChangeCameraModeFailed（続行）")
            }
            tookControl = true
            try checkStop()

            // 記録先。カードのまま映像が来るなら SDRAM に触らずに済むので、まずそれを試す。
            // だめだったカメラは覚えておき、次からは最初から SDRAM にする
            let needsSDRAM = UserDefaults.standard.bool(forKey: rememberKey)
            if needsSDRAM { try await setMedia(sdram: true) }
            var ok = try await beginAndWaitForFrame()
            if !ok && !needsSDRAM {
                try checkStop()
                log("ライブビュー: カードのままでは映像が来ない。SDRAM に切り替えて再試行")
                _ = try? await camera.send(.nikonEndLiveView)
                try await setMedia(sdram: true)
                ok = try await beginAndWaitForFrame()
                if ok { UserDefaults.standard.set(true, forKey: rememberKey) }
            }
            try checkStop()
            guard ok else { throw Failure.noFrames }

            state = .on
            runLoop()
            return nil
        } catch Failure.stopped {
            await teardown()
            finishStopping()
            return nil
        } catch {
            let message = await explain(error)
            log("ライブビュー: 開始できない \(message)")
            await teardown()
            finishStopping()
            return message
        }
    }

    private enum Failure: Error { case noFrames, stopped }

    private func checkStop() throws {
        if stopRequested { throw Failure.stopped }
    }

    /// 開始の命令を送り、準備ができるのを待ってから最初の 1 コマが取れるか確かめる
    private func beginAndWaitForFrame() async throws -> Bool {
        // 撮影の直後などでまだ手が離せないうちに開始すると断られるので、先に落ち着くのを待つ
        await camera.waitUntilReady(seconds: 3)
        var attempt = 0
        while true {
            try checkStop()
            attempt += 1
            do {
                try await camera.send(.nikonStartLiveView)
                break
            } catch PTPError.response(0x2019) {
                // DeviceBusy は libgphoto2 も成功扱いにして待つ
                break
            } catch PTPError.response(let code) {
                // カメラが開始そのものを拒否した。記録先がカードのままだと D300 はここで即座に断る
                // （禁止条件 0x00000001）。それは呼び出し側が SDRAM に切り替えて再試行する
                let condition = await readProhibitCondition()
                log("ライブビュー: 開始命令を拒否された \(PTP.responseName(code))（\(attempt) 回目）")
                guard let condition, attempt < 8 else { return false }
                if condition & 1 != 0 {
                    // 記録先がカード。SDRAM で開いている最中なら、撮り終えたカメラが自分でカードに戻したので切り替え直す
                    guard switchedToSDRAM else { return false }
                    try? await writeMedia(sdram: true)
                }
                // 撮影後の書き込み中（ビット 15）や、理由が出ていないだけのときは少し待てば通ることがある
                guard condition & ~((1 << 15) | 1) == 0 else { return false }
                try? await Task.sleep(for: .milliseconds(500))
                await camera.waitUntilReady(seconds: 2)
            }
        }
        // ミラーが上がって準備ができるまで（D300 で 1 秒ほど）
        try checkStop()
        await camera.waitUntilReady(seconds: 5)
        for _ in 0..<15 {
            try checkStop()
            do {
                let data = try await camera.send(.nikonGetLiveViewImg)
                if let jpeg = Self.jpeg(in: data) {
                    onFrame?(jpeg)
                    return true
                }
            } catch PTPError.response(let code) where code == 0xA00B || code == 0x2019 {
                // まだ始まっていない、またはビジー
            }
            try? await Task.sleep(for: .milliseconds(150))
        }
        return false
    }

    /// Nikon のライブビュー画像は独自ヘッダ（D300 で 64 バイト）の後ろに JPEG が続く
    public static func jpeg(in data: Data) -> Data? {
        let bytes = [UInt8](data.prefix(4096))
        guard bytes.count > 3,
              let start = (0..<(bytes.count - 2)).first(where: { bytes[$0] == 0xFF && bytes[$0 + 1] == 0xD8 && bytes[$0 + 2] == 0xFF })
        else { return nil }
        return data.subdata(in: (data.startIndex + start)..<data.endIndex)
    }

    // MARK: コマ取り

    private func runLoop() {
        loop?.cancel()
        loop = Task { [weak self] in
            var errors = 0
            while !Task.isCancelled {
                guard let self else { return }
                // 撮影中や設定の書き込み中は割り込まない
                if self.pauseCount > 0 || self.shouldPauseFrames() {
                    try? await Task.sleep(for: .milliseconds(60))
                    continue
                }
                do {
                    let data = try await self.camera.send(.nikonGetLiveViewImg)
                    guard !Task.isCancelled else { return }
                    if let jpeg = Self.jpeg(in: data) { self.onFrame?(jpeg) }
                    errors = 0
                } catch PTPError.response(0x2019) {
                    try? await Task.sleep(for: .milliseconds(40))
                } catch PTPError.response(0xA00B) {
                    // カメラ側でライブビューが止まった（撮影の直後、本体の操作、温度など）。1 度だけ開き直す
                    guard !Task.isCancelled, self.pauseCount == 0 else { continue }
                    self.log("ライブビュー: カメラ側で止まった。開き直す")
                    if (try? await self.beginAndWaitForFrame()) != true {
                        await self.stop(reason: "カメラ側で止まり、開き直せなかった")
                        return
                    }
                } catch {
                    errors += 1
                    if errors >= 5 {
                        await self.stop(reason: "コマ取りが続けて失敗: \(error.localizedDescription)")
                        return
                    }
                    try? await Task.sleep(for: .milliseconds(100))
                }
            }
        }
    }

    /// 撮影の間はライブビューを止めて、記録先をカードに戻しておく。撮り終えたら開き直す。
    ///
    /// ライブビューを付けたまま記録先だけカードに戻して切ると、D300 はシャッター音が 3 回鳴り、
    /// 画像が届かず、そのあとライブビューを開始できなくなった。D300 本体もライブビュー中の撮影では
    /// ミラーを下ろすので、止めてから普段どおりに撮るのが一番確実。
    ///
    /// - Parameters:
    ///   - shotCount: 撮影通知（ObjectAdded）を受けた回数。撮り終えたかの目安
    ///   - waitSeconds: 撮影通知を待つ上限（長秒時ノイズ低減のぶん長めに）
    ///   - body: シャッターを切る。命令が受け付けられたかを返す
    /// - Returns: 撮らずにやめたときの説明
    public func whileSuspended(shotCount: () -> Int, waitSeconds: Double,
                               _ body: () async -> Bool) async -> String? {
        guard state == .on else {
            _ = await body()
            return nil
        }
        pauseCount += 1
        suspended = true
        defer {
            suspended = false
            pauseCount = max(0, pauseCount - 1)
        }
        do {
            try await camera.send(.nikonEndLiveView)
        } catch {
            log("ライブビュー: 終了命令 失敗 \(error.localizedDescription)")
        }
        await camera.waitUntilReady(seconds: 3)
        if switchedToSDRAM {
            do {
                try await writeMedia(sdram: false)
            } catch {
                // カードに戻せないまま切ると SDRAM にしか残らない。撮らずにやめる
                log("ライブビュー: 記録先をカードに戻せない \(error.localizedDescription)")
                await stop(reason: "記録先をカードに戻せない")
                return String(localized: "記録先をカードに戻せなかったため、撮影をやめました。")
            }
        }

        let before = shotCount()
        let fired = await body()

        if fired {
            // 撮り終えるまで待つ。D300 は書き込みの間も DeviceReady は OK のまま開始命令だけを断り
            // （InvalidStatus・禁止条件 0）、書き終えると記録先を自分でカードに戻す。
            // 撮影通知（ObjectAdded）が届いてから開き直す
            let deadline = Date().addingTimeInterval(waitSeconds)
            while shotCount() == before, Date() < deadline, state == .on {
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
        await camera.waitUntilReady(seconds: 60)
        // 撮っている間にボタンやケーブル抜けで止められていたら、開き直さない
        guard state == .on else { return nil }
        do {
            if switchedToSDRAM { try await writeMedia(sdram: true) }
            if try await beginAndWaitForFrame() { return nil }
        } catch {
            log("ライブビュー: 撮影後の再開で失敗 \(error.localizedDescription)")
        }
        suspended = false
        pauseCount = 0
        await stop(reason: "撮影後に開き直せなかった")
        return nil
    }

    // MARK: 停止

    public func stop(reason: String) async {
        switch state {
        case .off, .stopping:
            return
        case .starting:
            // 開始処理が自分で片付ける
            stopRequested = true
            return
        case .on:
            break
        }
        state = .stopping
        loop?.cancel()
        loop = nil
        log("ライブビュー: 停止（\(reason)）")
        await teardown()
        finishStopping()
    }

    /// 止める命令を必ず送り、記録先と制御権をカメラに返す
    private func teardown() async {
        var steps: [String] = []
        func run(_ label: String, _ work: () async throws -> Void) async {
            do {
                try await work()
                steps.append("\(label) OK")
            } catch {
                steps.append("\(label) \(error.localizedDescription)")
            }
        }
        await run("終了") { try await camera.send(.nikonEndLiveView) }
        await camera.waitUntilReady(seconds: 3)
        if switchedToSDRAM {
            await run("カードへ") { try await self.writeMedia(sdram: false) }
            switchedToSDRAM = false
        }
        if tookControl {
            await run("制御権を返す") { try await camera.send(.nikonChangeCameraMode, params: [0]) }
            tookControl = false
        }
        log("ライブビュー: 後始末 \(steps.joined(separator: " / "))")
    }

    private func finishStopping() {
        pauseCount = 0
        state = .off
    }

    /// ケーブルが抜けた。命令は送れないので状態だけ捨てる。
    /// 記録先が SDRAM のまま残っている可能性は、次に接続したときに直す（restoreIfInterrupted）
    public func forget() {
        loop?.cancel()
        loop = nil
        tookControl = false
        switchedToSDRAM = false
        stopRequested = true
        finishStopping()
    }

    // MARK: 記録先

    private func setMedia(sdram: Bool) async throws {
        try await writeMedia(sdram: sdram)
        switchedToSDRAM = sdram
        log("ライブビュー: 記録先を \(sdram ? "SDRAM" : "カード") に")
    }

    private func writeMedia(sdram: Bool) async throws {
        try await camera.send(.setDevicePropValue, params: [Self.recordingMedia], outData: Data([sdram ? 1 : 0]))
    }

    /// 前回のライブビューが中断されて残っていたら、カメラを普段の状態に戻す。接続のたびに呼ぶ
    public static func restoreIfInterrupted(_ camera: PTPCamera) async {
        if let status = await camera.integer(liveViewStatus), status == 1 {
            _ = try? await camera.send(.nikonEndLiveView)
            _ = try? await camera.send(.nikonChangeCameraMode, params: [0])
            camera.log("前回のライブビューが残っていたので止めた")
        }
        if let media = await camera.integer(recordingMedia), media == 1 {
            _ = try? await camera.send(.setDevicePropValue, params: [recordingMedia], outData: Data([0]))
            camera.log("記録先が SDRAM のまま残っていたのでカードに戻した")
        }
    }

    // MARK: 失敗の説明

    private func readProhibitCondition() async -> UInt32? {
        await camera.integer(Self.prohibitCondition).map { UInt32(truncatingIfNeeded: $0) }
    }

    /// ログ用。カメラ側から見たライブビューの状態、記録先、禁止条件
    private func cameraState() async -> String {
        let status = await camera.integer(Self.liveViewStatus).map(String.init) ?? "?"
        let media = await camera.integer(Self.recordingMedia).map(String.init) ?? "?"
        let condition = await readProhibitCondition().map { String(format: "0x%08X", $0) } ?? "?"
        return "[LV=\(status) 記録先=\(media) 禁止=\(condition)]"
    }

    /// 開始できなかった理由を、カメラの禁止条件（libgphoto2 のビット定義）から言葉にする
    private func explain(_ error: Error) async -> String {
        log("ライブビュー: 失敗の元 \(error.localizedDescription)")
        guard let bits = await readProhibitCondition() else {
            return String(localized: "ライブビューを開始できませんでした。レリーズモードダイヤルが Lv になっていないか確認してください。")
        }
        func has(_ bit: Int) -> Bool { bits & (1 << bit) != 0 }
        if has(8)  { return String(localized: "カメラの電池が足りないため、ライブビューを開始できません。") }
        if has(17) { return String(localized: "カメラの温度が上がっているため、ライブビューを開始できません。しばらく休ませてください。") }
        if has(14) || has(18) || has(19) || has(20) {
            return String(localized: "カードを確認してください（入っていない、書き込み禁止、エラー、未フォーマットのいずれか）。")
        }
        if has(31) { return String(localized: "撮影モードを P・A・S・M のいずれかにしてください。") }
        if has(21) { return String(localized: "バルブではライブビューを使えません。") }
        if has(4)  { return String(localized: "シャッターボタンが押されたままです。") }
        if has(22) { return String(localized: "ミラーアップ中はライブビューを使えません。") }
        return String(localized: "ライブビューを開始できませんでした（\(String(format: "0x%08X", bits))）。レリーズモードダイヤルが Lv になっていないか確認してください。")
    }
}
