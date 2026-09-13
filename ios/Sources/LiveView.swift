import SwiftUI
import UIKit

// MARK: - ライブビューの制御

/// Nikon のライブビューを iOS から動かす。
///
/// 手順は libgphoto2（library.c）と同じで、probe で D300 の 640×426・27fps を確認している:
///   ChangeCameraMode(1) → 必要なら記録先を SDRAM に → StartLiveView → DeviceReady を待つ → GetLiveViewImg を繰り返す
///
/// 気をつけること（どれも実機で確かめた、または libgphoto2 のソースにある）
/// - カードの読み込みが終わるまでは、開始が OK でも映像が返らない（NotLiveView）
/// - D300 は記録先がカードのままだと開始を拒否する（禁止条件 0x00000001）。SDRAM に切り替えると通る
/// - 記録先を SDRAM にしたまま撮るとカードに残らない。撮るときはライブビューをいったん止めてカードへ戻す
///   （ライブビューを付けたまま記録先だけ戻して切ったら、シャッター音が 3 回鳴って画像が届かず、
///    以後ライブビューが開始できなくなった）
/// - 止める命令を省くとミラーが上がったまま残る（Mac 版で確認）
/// - レリーズモードダイヤルが Lv だとカメラが開始を拒否する
@MainActor
final class LiveViewController: ObservableObject {

    enum State: Equatable { case off, starting, on, stopping }

    @Published private(set) var state: State = .off
    /// 撮影のために一時的に止めている。映像は最後のコマのまま
    @Published private(set) var suspended = false
    /// 映像は毎秒 27 回変わるので、画面全体を描き直さないよう別の観測対象に分ける
    let feed = LiveFeed()
    weak var session: CameraSession?

    private var loop: Task<Void, Never>?
    private var tookControl = false
    /// こちらで記録先を SDRAM に切り替えた。止めるときにカードへ戻す
    private var switchedToSDRAM = false
    /// 撮影などで一時的にコマ取りを止めている数
    private var pauseCount = 0
    /// 開始処理の途中で止めるよう頼まれた
    private var stopRequested = false

    private static let recordingMedia: UInt32 = 0xD10B        // 0 = カード, 1 = SDRAM
    private static let liveViewStatus: UInt32 = 0xD1A2
    private static let prohibitCondition: UInt32 = 0xD1A4

    var isActive: Bool { state != .off }

    func toggle() {
        Task { state == .off ? await start() : await stop(reason: "ボタン") }
    }

    // MARK: 開始

    func start() async {
        guard state == .off, let s = session, s.isConnected, s.catalogReady, !s.pocketed else { return }
        state = .starting
        stopRequested = false
        await logWithState("ライブビュー: 開始")
        let key = "liveViewNeedsSDRAM.\(s.cameraIdentifier ?? "?")"

        do {
            // 制御権をホストへ。ChangeCameraModeFailed は libgphoto2 も無視して進む
            do {
                try await s.send(.nikonChangeCameraMode, params: [1])
                DebugLog.write("ライブビュー: 制御権 OK")
            } catch CameraError.ptp(0xA003) {
                DebugLog.write("ライブビュー: 制御権 ChangeCameraModeFailed（続行）")
            }
            tookControl = true
            try checkStop()

            // 記録先。カードのまま映像が来るなら SDRAM に触らずに済むので、まずそれを試す。
            // だめだったカメラは覚えておき、次からは最初から SDRAM にする
            let needsSDRAM = UserDefaults.standard.bool(forKey: key)
            if needsSDRAM { try await setMedia(sdram: true) }
            var ok = try await beginAndWaitForFrame()
            if !ok && !needsSDRAM {
                try checkStop()
                DebugLog.write("ライブビュー: カードのままでは映像が来ない。SDRAM に切り替えて再試行")
                try? await s.send(.nikonEndLiveView)
                try await setMedia(sdram: true)
                ok = try await beginAndWaitForFrame()
                if ok { UserDefaults.standard.set(true, forKey: key) }
            } else if ok && !needsSDRAM {
                DebugLog.write("ライブビュー: カードのまま映像が来た（SDRAM 不要）")
            }
            try checkStop()
            guard ok else { throw LiveViewFailure.noFrames }

            state = .on
            runLoop()
        } catch LiveViewFailure.stopped {
            await teardown()
            finishStopping()
        } catch {
            let message = await explain(error)
            DebugLog.write("ライブビュー: 開始できない \(message)")
            await teardown()
            finishStopping()
            s.lastError = message
        }
    }

    private func checkStop() throws {
        if stopRequested { throw LiveViewFailure.stopped }
    }

    /// 開始の命令を送り、準備ができるのを待ってから最初の 1 コマが取れるか確かめる
    private func beginAndWaitForFrame() async throws -> Bool {
        guard let s = session else { return false }
        // 撮影の直後などでまだ手が離せないうちに開始すると断られるので、先に落ち着くのを待つ
        await s.waitUntilReady(seconds: 3)
        var attempt = 0
        while true {
            try checkStop()
            attempt += 1
            do {
                try await s.send(.nikonStartLiveView)
                DebugLog.write("ライブビュー: 開始命令 OK")
                break
            } catch CameraError.ptp(0x2019) {
                // DeviceBusy は libgphoto2 も成功扱いにして待つ
                DebugLog.write("ライブビュー: 開始命令 DeviceBusy（待つ）")
                break
            } catch CameraError.ptp(let code) {
                // カメラが開始そのものを拒否した。記録先がカードのままだと D300 はここで即座に断る
                // （禁止条件 0x00000001）。それは呼び出し側が SDRAM に切り替えて再試行する
                let condition = await readProhibitCondition()
                await logWithState("ライブビュー: 開始命令を拒否された \(PTP.responseName(code))（\(attempt) 回目）")
                // 撮影後の書き込み中（ビット 15）や、理由が出ていないだけのときは少し待てば通ることがある
                let settling = condition.map { $0 & ~(1 << 15) == 0 } ?? false
                guard settling, attempt < 8 else { return false }
                try? await Task.sleep(for: .milliseconds(500))
                await s.waitUntilReady(seconds: 2)
            }
        }
        // ミラーが上がって準備ができるまで（D300 で 1 秒ほど）
        try checkStop()
        await s.waitUntilReady(seconds: 5)
        for _ in 0..<15 {
            try checkStop()
            do {
                let data = try await s.send(.nikonGetLiveViewImg)
                if let image = await LiveFeed.decode(data) {
                    feed.show(image)
                    return true
                }
            } catch CameraError.ptp(let code) where code == 0xA00B || code == 0x2019 {
                // まだ始まっていない、またはビジー
            }
            try? await Task.sleep(for: .milliseconds(150))
        }
        return false
    }

    // MARK: コマ取り

    private func runLoop() {
        loop?.cancel()
        loop = Task { [weak self] in
            var errors = 0
            while !Task.isCancelled {
                guard let self, let s = self.session else { return }
                // 撮影中や設定の書き込み中は割り込まない
                if self.pauseCount > 0 || s.busy {
                    try? await Task.sleep(for: .milliseconds(60))
                    continue
                }
                do {
                    let data = try await s.send(.nikonGetLiveViewImg)
                    guard !Task.isCancelled else { return }
                    if let image = await LiveFeed.decode(data) {
                        self.feed.show(image)
                    }
                    errors = 0
                } catch CameraError.ptp(0x2019) {
                    try? await Task.sleep(for: .milliseconds(40))
                } catch CameraError.ptp(0xA00B) {
                    // カメラ側でライブビューが止まった（撮影の直後、本体の操作、温度など）。1 度だけ開き直す
                    guard !Task.isCancelled, self.pauseCount == 0 else { continue }
                    DebugLog.write("ライブビュー: カメラ側で止まった。開き直す")
                    if (try? await self.beginAndWaitForFrame()) != true {
                        await self.stop(reason: "カメラ側で止まり、開き直せなかった")
                        return
                    }
                } catch {
                    errors += 1
                    if errors >= 5 {
                        await self.stop(reason: "コマ取りが続けて失敗: \(error)")
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
    /// ミラーを下ろすので、止めてから普段どおりに撮るのが一番確実
    func whileSuspended(_ body: () async -> Void) async {
        guard state == .on, let s = session else { return await body() }
        pauseCount += 1
        suspended = true
        defer {
            suspended = false
            pauseCount = max(0, pauseCount - 1)
        }
        DebugLog.write("ライブビュー: 撮影のため止める")
        do {
            try await s.send(.nikonEndLiveView)
        } catch {
            DebugLog.write("ライブビュー: 終了命令 失敗 \(error)")
        }
        await s.waitUntilReady(seconds: 3)
        if switchedToSDRAM {
            do {
                try await writeMedia(sdram: false)
            } catch {
                // カードに戻せないまま切ると SDRAM にしか残らない。撮らずにやめる
                await logWithState("ライブビュー: 記録先をカードに戻せない \(error)")
                s.lastError = String(localized: "記録先をカードに戻せなかったため、撮影をやめました。")
                await stop(reason: "記録先をカードに戻せない")
                return
            }
        }
        await logWithState("ライブビュー: 撮影前")

        await body()

        // 露光とカードへの書き込みが終わるまでビジーが続く
        await s.waitUntilReady(seconds: 60)
        // 撮っている間にボタンやケーブル抜けで止められていたら、開き直さない
        guard state == .on else { return }
        do {
            if switchedToSDRAM { try await writeMedia(sdram: true) }
            if try await beginAndWaitForFrame() {
                DebugLog.write("ライブビュー: 撮影後に再開")
                return
            }
        } catch {
            DebugLog.write("ライブビュー: 撮影後の再開で失敗 \(error)")
        }
        suspended = false
        pauseCount = 0
        await stop(reason: "撮影後に開き直せなかった")
    }

    // MARK: 停止

    func stop(reason: String) async {
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
        DebugLog.write("ライブビュー: 停止（\(reason)）")
        await teardown()
        finishStopping()
    }

    /// 止める命令を必ず送り、記録先と制御権をカメラに返す
    private func teardown() async {
        guard let s = session, s.isConnected else { return }
        var steps: [String] = []
        func run(_ label: String, _ work: () async throws -> Void) async {
            do {
                try await work()
                steps.append("\(label) OK")
            } catch CameraError.ptp(let code) {
                steps.append("\(label) \(PTP.responseName(code))")
            } catch {
                steps.append("\(label) \(error)")
            }
        }
        await run("終了") { try await s.send(.nikonEndLiveView) }
        await s.waitUntilReady(seconds: 3)
        if switchedToSDRAM {
            await run("カードへ") { try await self.writeMedia(sdram: false) }
            switchedToSDRAM = false
        }
        if tookControl {
            await run("制御権を返す") { try await s.send(.nikonChangeCameraMode, params: [0]) }
            tookControl = false
        }
        await logWithState("ライブビュー: 後始末 \(steps.joined(separator: " / "))")
    }

    private func finishStopping() {
        feed.clear()
        pauseCount = 0
        state = .off
    }

    /// ケーブルが抜けた。命令は送れないので状態だけ捨てる。
    /// 記録先が SDRAM のまま残っている可能性は、次に接続したときに直す
    func forget() {
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
        DebugLog.write("ライブビュー: 記録先を \(sdram ? "SDRAM" : "カード") に")
    }

    private func writeMedia(sdram: Bool) async throws {
        guard let s = session else { return }
        try await s.send(.setDevicePropValue, params: [Self.recordingMedia], outData: Data([sdram ? 1 : 0]))
    }

    /// 前回のライブビューが中断されて残っていたら、カメラを普段の状態に戻す。接続のたびに呼ぶ
    static func restoreIfInterrupted(_ s: CameraSession) async {
        if let d = try? await s.send(.getDevicePropValue, params: [liveViewStatus]), d.first == 1 {
            try? await s.send(.nikonEndLiveView)
            try? await s.send(.nikonChangeCameraMode, params: [0])
            DebugLog.write("前回のライブビューが残っていたので止めた")
        }
        if let d = try? await s.send(.getDevicePropValue, params: [recordingMedia]), d.first == 1 {
            try? await s.send(.setDevicePropValue, params: [recordingMedia], outData: Data([0]))
            DebugLog.write("記録先が SDRAM のまま残っていたのでカードに戻した")
        }
    }

    // MARK: 失敗の説明

    enum LiveViewFailure: Error { case noFrames, stopped }

    private func readProhibitCondition() async -> UInt32? {
        guard let s = session,
              let d = try? await s.send(.getDevicePropValue, params: [Self.prohibitCondition]), d.count >= 4 else { return nil }
        return UInt32(d[d.startIndex]) | UInt32(d[d.startIndex + 1]) << 8
             | UInt32(d[d.startIndex + 2]) << 16 | UInt32(d[d.startIndex + 3]) << 24
    }

    private func logWithState(_ message: String) async {
        let state = await cameraState()
        DebugLog.write("\(message) \(state)")
    }

    /// ログ用。カメラ側から見たライブビューの状態、記録先、禁止条件、DeviceReady の応答
    private func cameraState() async -> String {
        guard let s = session else { return "" }
        func byte(_ prop: UInt32) async -> String {
            guard let d = try? await s.send(.getDevicePropValue, params: [prop]), let b = d.first else { return "?" }
            return String(b)
        }
        let status = await byte(Self.liveViewStatus)
        let media = await byte(Self.recordingMedia)
        let condition = await readProhibitCondition().map { String(format: "0x%08X", $0) } ?? "?"
        let ready: String
        do {
            try await s.send(.nikonDeviceReady)
            ready = "OK"
        } catch CameraError.ptp(let code) {
            ready = PTP.responseName(code)
        } catch {
            ready = "\(error)"
        }
        return "[LV=\(status) 記録先=\(media) 禁止=\(condition) Ready=\(ready)]"
    }

    /// 開始できなかった理由を、カメラの禁止条件（libgphoto2 のビット定義）から言葉にする
    private func explain(_ error: Error) async -> String {
        DebugLog.write("ライブビュー: 失敗の元 \(error)")
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

// MARK: - 映像

/// ライブビューの 1 コマと、実際に出ているコマ数
@MainActor
final class LiveFeed: ObservableObject {
    @Published private(set) var frame: UIImage?
    @Published private(set) var fps: Double = 0

    private var count = 0
    private var windowStart = Date()

    func show(_ image: UIImage) {
        frame = image
        count += 1
        let elapsed = Date().timeIntervalSince(windowStart)
        if elapsed >= 1 {
            fps = Double(count) / elapsed
            count = 0
            windowStart = Date()
        }
    }

    func clear() {
        frame = nil
        fps = 0
        count = 0
        windowStart = Date()
    }

    /// Nikon のライブビュー画像は独自ヘッダ（D300 で 64 バイト）の後ろに JPEG が続く。
    /// 描画時に主スレッドで展開されないよう、ここで展開まで済ませる
    nonisolated static func decode(_ data: Data) async -> UIImage? {
        await Task.detached(priority: .userInitiated) { () -> UIImage? in
            let bytes = [UInt8](data.prefix(4096))
            guard bytes.count > 3,
                  let start = (0..<(bytes.count - 2)).first(where: { bytes[$0] == 0xFF && bytes[$0 + 1] == 0xD8 && bytes[$0 + 2] == 0xFF })
            else { return nil }
            let jpeg = data.subdata(in: (data.startIndex + start)..<data.endIndex)
            return UIImage(data: jpeg)?.preparingForDisplay()
        }.value
    }
}

// MARK: - 画面

/// 上のプレビュー欄。ライブビュー中は映像に置き換える
struct PreviewSwitcher: View {
    @EnvironmentObject var session: CameraSession
    @ObservedObject var live: LiveViewController
    @State private var fullScreen = false

    var body: some View {
        ZStack(alignment: .topTrailing) {
            if live.state == .off {
                ShotPreviewArea()
            } else {
                LivePane(feed: live.feed, stopping: live.state == .stopping, shooting: live.suspended) { fullScreen = true }
            }
            LiveViewToggle(live: live)
                .padding(10)
        }
        .fullScreenCover(isPresented: $fullScreen) {
            LiveFullScreen(live: live, feed: live.feed).environmentObject(session)
        }
        .onChange(of: live.state) { _, state in
            if state == .off { fullScreen = false }
        }
    }
}

/// ライブビューの開始・停止ボタン。Nikon のカメラがつながっているときだけ出す
struct LiveViewToggle: View {
    @EnvironmentObject var session: CameraSession
    @ObservedObject var live: LiveViewController

    var body: some View {
        if session.isConnected, PropFormat.vendor == PropFormat.vendorNikon {
            // カードの読み込み中は映像が返らないので押せなくする
            let ready = session.catalogReady
            Button { live.toggle() } label: {
                HStack(spacing: 5) {
                    switch live.state {
                    case .starting, .stopping:
                        ProgressView().controlSize(.mini)
                    case .on:
                        Image(systemName: "stop.fill").font(.system(size: 9, weight: .bold))
                    case .off:
                        Image(systemName: "video.fill").font(.system(size: 10, weight: .semibold))
                    }
                    Text(label(ready: ready))
                        .font(.system(size: 11, weight: .semibold))
                }
                .foregroundStyle(live.state == .on ? Color.white : Color.primary)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background {
                    if live.state == .on {
                        Capsule().fill(Color.red.opacity(0.85))
                    } else {
                        Capsule().fill(.ultraThinMaterial)
                    }
                }
            }
            .buttonStyle(.plain)
            .disabled(live.state == .off && !ready || live.state == .starting || live.state == .stopping)
            .opacity(live.state == .off && !ready ? 0.5 : 1)
        }
    }

    private func label(ready: Bool) -> String {
        switch live.state {
        case .on: return String(localized: "停止")
        case .starting: return String(localized: "開始中")
        case .stopping: return String(localized: "停止中")
        case .off: return ready ? String(localized: "ライブビュー") : String(localized: "読み込み後に使えます")
        }
    }
}

/// 上のプレビュー欄に出す映像
struct LivePane: View {
    @ObservedObject var feed: LiveFeed
    let stopping: Bool
    /// 撮影のために止めている間は最後のコマを暗くして出す
    let shooting: Bool
    let onFullScreen: () -> Void

    var body: some View {
        ZStack {
            Color.black
            if let frame = feed.frame {
                Image(uiImage: frame)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .opacity(stopping || shooting ? 0.4 : 1)
            } else {
                ProgressView().tint(.white)
            }
            if shooting { ShootingBadge() }
            VStack {
                HStack {
                    LiveBadge(fps: feed.fps)
                    Spacer()
                }
                Spacer()
                HStack {
                    Spacer()
                    Button(action: onFullScreen) {
                        Image(systemName: "arrow.up.left.and.arrow.down.right")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 36, height: 36)
                            .background(.ultraThinMaterial, in: Circle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(10)
        }
    }
}

/// 撮影でライブビューを止めている間の表示
struct ShootingBadge: View {
    var body: some View {
        HStack(spacing: 6) {
            ProgressView().controlSize(.small).tint(.white)
            Text("撮影中").font(.system(size: 13, weight: .semibold))
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(.black.opacity(0.5), in: Capsule())
    }
}

struct LiveBadge: View {
    let fps: Double

    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(Color.red).frame(width: 7, height: 7)
            Text("LIVE").font(.system(size: 10, weight: .bold))
            if fps > 0 {
                Text(String(format: "%.0f fps", fps))
                    .font(.system(size: 10).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.7))
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(.black.opacity(0.45), in: Capsule())
    }
}

/// 横向き全面のライブビュー。端末は縦のまま、中身を 90 度回す（全画面プレビューと同じ作り）
struct LiveFullScreen: View {
    @EnvironmentObject var session: CameraSession
    @ObservedObject var live: LiveViewController
    @ObservedObject var feed: LiveFeed
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color.black.ignoresSafeArea()
                content
                    .frame(width: geo.size.height, height: geo.size.width)
                    .rotationEffect(.degrees(90))
                    .frame(width: geo.size.width, height: geo.size.height)
            }
        }
        .ignoresSafeArea()
        .statusBarHidden()
    }

    private var content: some View {
        ZStack {
            if let frame = feed.frame {
                Image(uiImage: frame)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .opacity(live.suspended ? 0.4 : 1)
            } else {
                ProgressView().tint(.white)
            }
            if live.suspended { ShootingBadge() }

            // 回転させているぶん、端末の角丸とダイナミックアイランドに食い込みやすい。左右は多めに逃がす
            HStack {
                VStack(alignment: .leading) {
                    Button { dismiss() } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 36, height: 36)
                            .background(.ultraThinMaterial, in: Circle())
                    }
                    .buttonStyle(.plain)
                    Spacer()
                    LiveBadge(fps: feed.fps)
                }
                Spacer()
                Button {
                    Task { await session.capture() }
                } label: {
                    Group {
                        if session.busy {
                            ProgressView().tint(.white)
                        } else {
                            Image(systemName: "camera.shutter.button").font(.system(size: 26))
                        }
                    }
                    .frame(width: 62, height: 62)
                }
                .buttonStyle(.borderedProminent)
                .clipShape(Circle())
                .disabled(session.busy)
            }
            .padding(.horizontal, 46)
            .padding(.vertical, 22)
        }
    }
}
