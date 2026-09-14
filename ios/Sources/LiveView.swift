import SwiftUI
import TethrUI
import UIKit
import TethrKit

// MARK: - ライブビューの制御

/// ライブビューを画面につなぐ。命令の手順は TethrKit の NikonLiveView（Mac 版と共通）が持ち、
/// ここは iOS だけの事情を足す: 放置で止める、映像を UIImage にして出す、手応え、エラーの見せ方、デモ。
///
/// 開始できるのはカードの読み込みが終わってから（それまでは開始が OK でも映像が返らない）
@MainActor
final class LiveViewController: ObservableObject {

    typealias State = NikonLiveView.State

    @Published private(set) var state: State = .off
    /// 撮影のために一時的に止めている。映像は最後のコマのまま
    @Published private(set) var suspended = false
    /// 放置で自動的に止まるまでの残り秒数。残りわずかになったときだけ入る
    @Published private(set) var autoStopIn: Int?
    /// 映像は毎秒 27 回変わるので、画面全体を描き直さないよう別の観測対象に分ける
    let feed = LiveFeed()
    weak var session: CameraSession?

    private var engine: NikonLiveView?
    private var idleWatch: Task<Void, Never>?
    #if DEBUG
    private var demoLoop: Task<Void, Never>?
    #endif

    /// 操作されないままこの秒数が過ぎたら止める。
    /// ライブビューはミラーを上げてセンサーを動かし続けるので、つないでいる間で一番電池を食う
    private static var idleLimit: TimeInterval {
        #if DEBUG
        // 起動引数 -liveIdle=20 で短くして確かめる
        if let arg = ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix("-liveIdle=") }),
           let seconds = TimeInterval(arg.dropFirst("-liveIdle=".count)) { return seconds }
        #endif
        return 120
    }
    /// 残りがこの秒数を切ったら、止まることを知らせる
    private static let countdownFrom: TimeInterval = 15

    var isActive: Bool { state != .off }

    /// カメラとのやり取りを受け持つ相手を決める。セッションを開いたカメラごとに 1 つ
    func attach(_ camera: PTPCamera, identifier: String) {
        guard engine == nil else { return }
        let engine = NikonLiveView(camera: camera, cameraIdentifier: identifier)
        engine.onChange = { [weak self] in self?.engineChanged() }
        engine.onFrame = { [weak self] jpeg in self?.feed.submit(jpeg) }
        // 撮影中は割り込まない
        engine.shouldPauseFrames = { [weak self] in self?.session?.busy ?? false }
        self.engine = engine
    }

    func toggle() {
        Task { state == .off ? await start() : await stop(reason: "ボタン") }
    }

    // MARK: 開始と停止

    func start() async {
        guard state == .off, let s = session, s.isConnected, s.catalogReady, !s.pocketed else { return }
        #if DEBUG
        if s.demo { return await startDemo() }
        #endif
        guard let engine else { return }
        if let message = await engine.start() {
            s.lastError = message
        } else if engine.state == .on {
            Haptics.success()
        }
    }

    func stop(reason: String) async {
        #if DEBUG
        if session?.demo == true {
            demoLoop?.cancel()
            demoLoop = nil
            finishStopping()
            return
        }
        #endif
        await engine?.stop(reason: reason)
    }

    /// 撮影の間はライブビューを止めて、記録先をカードに戻しておく。撮り終えたら開き直す（手順は NikonLiveView）
    func whileSuspended(_ body: () async -> Bool) async {
        guard let engine, let s = session else {
            _ = await body()
            return
        }
        if let problem = await engine.whileSuspended(shotCount: { s.shotNotificationCount },
                                                     waitSeconds: s.captureWaitSeconds, body) {
            s.lastError = problem
        }
    }

    /// ケーブルが抜けた。命令は送れないので状態だけ捨てる。
    /// 記録先が SDRAM のまま残っている可能性は、次に接続したときに直す
    func forget() {
        engine?.forget()
        engine = nil
        #if DEBUG
        demoLoop?.cancel()
        demoLoop = nil
        #endif
        finishStopping()
    }

    private func engineChanged() {
        guard let engine else { return }
        let wasOn = state == .on
        state = engine.state
        suspended = engine.suspended
        if state == .on, !wasOn {
            watchIdle()
        } else if state == .off {
            finishStopping()
        }
    }

    private func finishStopping() {
        idleWatch?.cancel()
        idleWatch = nil
        autoStopIn = nil
        feed.clear()
        suspended = false
        state = .off
    }

    // MARK: 放置

    private func watchIdle() {
        idleWatch?.cancel()
        Interaction.touch()
        idleWatch = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self, self.state == .on else { return }
                // 撮っている間は数えない（長秒時で待たされても止めない）
                if self.suspended || self.session?.busy == true { Interaction.touch() }
                let remaining = Self.idleLimit - Interaction.idleSeconds
                if remaining <= 0 {
                    Haptics.toggle()
                    await self.stop(reason: "\(Int(Self.idleLimit)) 秒操作なし")
                    return
                }
                let shown = remaining <= Self.countdownFrom ? Int(remaining.rounded(.up)) : nil
                if shown != self.autoStopIn { self.autoStopIn = shown }
            }
        }
    }

    #if DEBUG
    /// デモ（起動引数 -demo）では、太陽が動くだけの映像を流す
    private func startDemo() async {
        state = .starting
        let frames = (0..<24).map { i -> UIImage in
            DemoImage.make(seed: 4, portrait: false, sunShift: Double(i) / 24)
                .preparingThumbnail(of: CGSize(width: 640, height: 426)) ?? UIImage()
        }
        try? await Task.sleep(for: .milliseconds(600))
        guard state == .starting else { return }
        state = .on
        Haptics.success()
        watchIdle()
        demoLoop = Task { [weak self] in
            var i = 0
            while !Task.isCancelled {
                guard let self else { return }
                if !self.suspended { self.feed.show(frames[i % frames.count]) }
                i += 1
                try? await Task.sleep(for: .milliseconds(37))
            }
        }
    }
    #endif
}

// MARK: - 映像

/// ライブビューの 1 コマと、実際に出ているコマ数
@MainActor
final class LiveFeed: ObservableObject {
    @Published private(set) var frame: UIImage?
    @Published private(set) var fps: Double = 0

    private var count = 0
    private var windowStart = Date()
    /// 展開を待っている最新のコマ。展開が追いつかなければ古いコマは飛ばす
    private var pending: Data?
    private var decoding = false
    /// 止めたあとに、展開中だったコマが遅れて出ないようにする
    private var generation = 0

    /// 届いた JPEG を主スレッドの外で展開してから出す。届いた順は崩さない
    func submit(_ jpeg: Data) {
        pending = jpeg
        guard !decoding else { return }
        decoding = true
        Task {
            while let data = pending {
                pending = nil
                let started = generation
                let image = await Self.decode(data)
                if let image, started == generation { show(image) }
            }
            decoding = false
        }
    }

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
        generation += 1
        pending = nil
        frame = nil
        fps = 0
        count = 0
        windowStart = Date()
    }

    /// 描画時に主スレッドで展開されないよう、ここで展開まで済ませる
    nonisolated static func decode(_ jpeg: Data) async -> UIImage? {
        await Task.detached(priority: .userInitiated) { () -> UIImage? in
            UIImage(data: jpeg)?.preparingForDisplay()
        }.value
    }
}

// MARK: - 画面

/// 上のプレビュー欄。ライブビュー中は映像に置き換える
struct PreviewSwitcher: View {
    @EnvironmentObject var session: CameraSession
    @ObservedObject var live: LiveViewController
    @Binding var fullScreen: Bool

    var body: some View {
        Group {
            if live.state == .off {
                ShotPreviewArea()
            } else {
                LivePane(feed: live.feed, stopping: live.state == .stopping, shooting: live.suspended)
            }
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
        if session.isConnected, session.supportsLiveView {
            // カードの読み込み中は映像が返らないので押せなくする
            let ready = session.catalogReady
            Button {
                Haptics.toggle()
                live.toggle()
            } label: {
                Group {
                    switch live.state {
                    case .starting, .stopping:
                        ProgressView().controlSize(.small).tint(Theme.dim)
                    case .on:
                        Image(systemName: "video.fill")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(Theme.onAmber)
                    case .off:
                        Image(systemName: "video")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(Theme.text)
                    }
                }
                .frame(width: 36, height: 36)
                .glassCircle(tint: live.state == .on ? Theme.amber : nil)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(live.state == .off && !ready || live.state == .starting || live.state == .stopping)
            .opacity(live.state == .off && !ready ? 0.4 : 1)
            .accessibilityLabel(Text("ライブビュー"))
            .accessibilityValue(Text(label(ready: ready)))
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

/// 上のプレビュー欄に出す映像。写真と同じく、上には何も重ねない
struct LivePane: View {
    @ObservedObject var feed: LiveFeed
    let stopping: Bool
    /// 撮影のために止めている間は最後のコマを暗くして出す
    let shooting: Bool

    var body: some View {
        ZStack {
            Theme.background
            if let frame = feed.frame {
                Image(uiImage: frame)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .opacity(stopping || shooting ? 0.4 : 1)
            } else {
                ProgressView().tint(Theme.dim)
            }
        }
    }
}

/// 写真の下の段に出す、ライブビューの状態。映像は毎秒 27 回変わるので、この部分だけが描き直される
struct LiveStatus: View {
    @ObservedObject var feed: LiveFeed
    let state: LiveViewController.State
    let shooting: Bool
    /// 放置で止まるまでの残り秒数
    let autoStopIn: Int?

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(Theme.live).frame(width: 7, height: 7)
            Text("LIVE").font(.system(size: 12, weight: .bold))
            Group {
                if shooting {
                    Text("撮影中")
                } else if state == .starting {
                    Text("開始中")
                } else if state == .stopping {
                    Text("停止中")
                } else if let autoStopIn {
                    // 触れば止まらない。数字が減っていくのが見えるようにする
                    Text("\(autoStopIn) 秒で停止").monospacedDigit()
                        .foregroundStyle(Theme.amber)
                        .contentTransition(.numericText(countsDown: true))
                } else if feed.fps > 0 {
                    Text(String(format: "%.0f fps", feed.fps)).monospacedDigit()
                }
            }
            .font(.system(size: 12))
            .foregroundStyle(Theme.dim)
            .animation(.snappy(duration: 0.2), value: autoStopIn)
        }
    }
}

struct LiveBadge: View {
    let fps: Double
    var autoStopIn: Int?

    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(Theme.live).frame(width: 7, height: 7)
            Text("LIVE").font(.system(size: 11, weight: .bold))
            if let autoStopIn {
                Text("\(autoStopIn) 秒で停止")
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(Theme.amber)
            } else if fps > 0 {
                Text(String(format: "%.0f fps", fps))
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.7))
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(.black.opacity(0.5), in: Capsule())
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
                            .frame(width: 44, height: 44)
                            .glassCircle()
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text("閉じる"))
                    Spacer()
                    LiveBadge(fps: feed.fps, autoStopIn: live.autoStopIn)
                }
                Spacer()
                ShutterButton(size: 72, busy: session.busy, enabled: true) {
                    Haptics.shutter()
                    Task { await session.capture() }
                }
            }
            .padding(.horizontal, 46)
            .padding(.vertical, 22)
        }
    }
}
