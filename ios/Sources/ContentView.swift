import SwiftUI
import ImageIO
import TethrKit
import UniformTypeIdentifiers

/// 撮影の画面。上から、カメラの名前 → 写真 → 写真の情報 → コマの一覧 → 露出 → シャッター。
///
/// 写真の上には何も重ねない（構図を見るのが一番の用事なので）。
/// 露出の操作は撮影モードで入れ替え、シャッターは親指の届く下の中央に置く
struct ContentView: View {
    @EnvironmentObject var session: CameraSession
    @State private var reviewing = false
    @State private var liveFullScreen = false
    /// 起動した最初の画面から待ち画面を出しておく。通常の画面が一瞬見えてから切り替わらないように
    @State private var showPreparing = true
    @State private var preparingReveal: Date?
    /// 起動直後、つながっているカメラが見つかるまでの猶予。見つからなければ待ち画面を閉じる
    @State private var launching = true

    var body: some View {
        VStack(spacing: 0) {
            TopBar()
            PreviewSwitcher(live: session.live, fullScreen: $liveFullScreen)
            PreviewInfoRow(live: session.live, openLiveFullScreen: { liveFullScreen = true })
            ShotStrip()
            ControlPanel()
        }
        .background(Theme.background)
        .foregroundStyle(Theme.text)
        .tint(Theme.amber)
        .alert("エラー", isPresented: Binding(
            get: { session.lastError != nil },
            set: { if !$0 { session.lastError = nil } }
        )) {
            Button("OK") { session.lastError = nil }
        } message: {
            Text(session.lastError ?? "")
        }
        .onChange(of: session.lastError) { _, message in
            if message != nil { Haptics.error() }
        }
        .fullScreenCover(isPresented: $reviewing) {
            ReviewView().environmentObject(session)
        }
        .environment(\.openReview, { reviewing = true })
        // ポケットから取り出したとき、中で撮ったカットがあれば最新を全画面で出す。
        // 背面液晶のレビューは USB でつないでいる間は出ないので、その代わり
        .onChange(of: session.reviewOnReturn) { _, id in
            guard id != nil else { return }
            reviewing = true
            session.reviewOnReturn = nil
        }
        // 接続直後の下調べの間は何もできないので、全面で待っていることを伝える
        .overlay {
            if showPreparing {
                PreparingOverlay(count: session.lastKnownFileCount, reveal: preparingReveal)
                    .ignoresSafeArea()
                    .transition(.opacity)
            }
        }
        .onChange(of: session.preparing) { _, _ in updatePreparingOverlay() }
        .onChange(of: session.state) { _, _ in updatePreparingOverlay() }
        .task {
            // つながっているカメラなら、ここまでに見つかってセッションを開き始めている
            try? await Task.sleep(for: .milliseconds(1200))
            launching = false
            updatePreparingOverlay()
        }
        .task {
            Interaction.installOnWindows()
            #if DEBUG
            if CameraSession.demoRequested {
                session.loadDemo()
                return
            }
            #endif
            if case .idle = session.state { session.start() }
        }
    }
}

extension ContentView {
    /// いま待ち画面を出すべきか。
    ///
    /// 起動直後はカメラが見つかるまで少し待つ。見つかれば準備（カードの下調べ）が終わるまで出し続け、
    /// 見つからない・許可が無い・失敗したときは閉じる。起動後のつなぎ直しでは、
    /// カードがほぼ空で一瞬で終わる場合にちらつかないよう 0.4 秒待ってから出す。
    fileprivate func updatePreparingOverlay() {
        let waiting: Bool
        switch session.state {
        case .idle, .searching, .connecting:
            waiting = launching || session.preparing
        case .connected:
            waiting = session.preparing
        case .failed, .unauthorized:
            waiting = false
        }

        if waiting {
            preparingReveal = nil
            guard !showPreparing else { return }
            Task {
                try? await Task.sleep(for: .milliseconds(400))
                guard session.preparing else { return }
                withAnimation(.easeIn(duration: 0.25)) { showPreparing = true }
            }
        } else if showPreparing, preparingReveal == nil {
            // 絞りを全開にしてから消す
            preparingReveal = Date()
            Task {
                try? await Task.sleep(for: .milliseconds(480))
                guard preparingReveal != nil else { return }
                withAnimation(.easeOut(duration: 0.3)) { showPreparing = false }
                preparingReveal = nil
            }
        }
    }
}

// MARK: - 上部

/// カメラの名前と、位置情報・電池。
/// 接続解除はめったに使わないので、名前を押したときのメニューに入れる
struct TopBar: View {
    @EnvironmentObject var session: CameraSession
    @State private var showGeoPanel = false

    var body: some View {
        HStack(spacing: 4) {
            CameraMenu()
            Spacer(minLength: 8)
            IconButton(systemName: session.geotagging ? "location.fill" : "location.slash",
                       tint: session.geotagging ? Theme.amber : Theme.dim,
                       filled: false,
                       label: Text("位置情報")) {
                showGeoPanel = true
            }
            if let battery = session.props[.batteryLevel] {
                BatteryIndicator(level: battery.current)
                    .padding(.trailing, 6)
            }
        }
        .padding(.leading, 14)
        .padding(.trailing, 6)
        .frame(height: 48)
        .sheet(isPresented: $showGeoPanel) {
            GeoPanel().environmentObject(session)
        }
    }
}

/// 機種名。つながっていれば押すとメニュー（時計合わせの結果・電池・接続解除）が開く
struct CameraMenu: View {
    @EnvironmentObject var session: CameraSession

    var body: some View {
        if session.preparing {
            status(spinner: true)
        } else if session.userDisconnected, case .idle = session.state {
            HStack(spacing: 10) {
                Text(session.deviceName ?? String(localized: "カメラ"))
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.dim)
                Button {
                    Haptics.toggle()
                    session.reconnect()
                } label: {
                    Text("接続")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.onAmber)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Theme.amber, in: Capsule())
                }
                .buttonStyle(.plain)
            }
        } else if case .connected(let name) = session.state {
            Menu {
                if let drift = session.clockCorrection, abs(drift) > 2 {
                    Label("カメラの時計を \(Int(abs(drift))) 秒ぶん合わせました",
                          systemImage: "clock.arrow.trianglehead.counterclockwise.rotate.90")
                }
                if let battery = session.props[.batteryLevel] {
                    Label {
                        Text("カメラの電池") + Text(" ") + Text(BatteryIndicator.rangeText(battery.current))
                    } icon: {
                        Image(systemName: BatteryIndicator.symbol(battery.current))
                    }
                }
                Section {
                    Button {
                        Haptics.toggle()
                        session.disconnect()
                    } label: {
                        Label("接続解除", systemImage: "eject")
                    }
                    .disabled(session.busy)
                }
            } label: {
                HStack(spacing: 7) {
                    Circle().fill(Theme.amber).frame(width: 7, height: 7)
                    Text(name)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Theme.text)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(Theme.dim)
                }
                .frame(height: 44)
                .contentShape(Rectangle())
            }
        } else {
            status(spinner: session.state == .searching || { if case .connecting = session.state { return true }; return false }())
        }
    }

    private func status(spinner: Bool) -> some View {
        HStack(spacing: 8) {
            if spinner {
                ProgressView().controlSize(.mini).tint(Theme.dim)
            } else {
                Circle().fill(dotColor).frame(width: 7, height: 7)
            }
            Text(text)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Theme.dim)
                .lineLimit(1)
        }
    }

    private var dotColor: Color {
        switch session.state {
        case .failed, .unauthorized: return Theme.danger
        default: return Theme.dimmer
        }
    }

    private var text: String {
        // 準備中はカードの枚数に比例して待たされ、その間は何も操作できない。
        // 前回の枚数から目安を出す（D300 で 1 件約 17 ミリ秒）
        if session.preparing {
            if let count = session.lastKnownFileCount, count > 0 {
                let seconds = max(1, Int((Double(count) * 0.017).rounded(.up)))
                return String(localized: "カードを確認中（\(count) 件・約 \(seconds) 秒）")
            }
            return String(localized: "カードを確認中…")
        }
        switch session.state {
        case .idle: return String(localized: "未接続")
        case .searching: return String(localized: "カメラを探しています…")
        case .connecting(let n): return String(localized: "\(n) に接続中…")
        case .connected(let n): return n
        case .unauthorized: return String(localized: "設定でカメラへのアクセスを許可してください")
        case .failed(let e): return e
        }
    }
}

/// カメラの電池。
///
/// D300 は残量を 20% 刻みの切り上げでしか返さない（本体メニューで 42% のとき 60）。
/// 数字で出すと実際より多く見えるので、段階のアイコンにする
struct BatteryIndicator: View {
    let level: Int64

    var body: some View {
        Image(systemName: Self.symbol(level))
            .font(.system(size: 15))
            .foregroundStyle(level <= 20 ? Theme.danger : Theme.dim)
            .accessibilityLabel(Text("カメラの電池"))
            .accessibilityValue(Text(Self.rangeText(level)))
    }

    static func rangeText(_ level: Int64) -> String {
        level >= 100 ? String(localized: "満充電") : String(localized: "\(max(0, level - 19))〜\(level)%")
    }

    static func symbol(_ level: Int64) -> String {
        switch level {
        case 81...:   return "battery.100percent"
        case 61...80: return "battery.75percent"
        case 41...60: return "battery.50percent"
        case 1...40:  return "battery.25percent"
        default:      return "battery.0percent"
        }
    }
}

// MARK: - プレビュー

/// 全画面確認モードを開くための受け渡し
private struct OpenReviewKey: EnvironmentKey {
    static let defaultValue: () -> Void = {}
}

extension EnvironmentValues {
    var openReview: () -> Void {
        get { self[OpenReviewKey.self] }
        set { self[OpenReviewKey.self] = newValue }
    }
}

/// 選んだカットの表示。写真の周りは画面の地と同じ色にして、余白が帯に見えないようにする
struct ShotPreviewArea: View {
    @EnvironmentObject var session: CameraSession
    @State private var zoom: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var offsetAtStart: CGSize = .zero
    @State private var fullImage: UIImage?

    private var shot: Shot? {
        session.shots.first { $0.id == session.selection } ?? session.shots.first
    }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Theme.background

                if let shot {
                    if let image = fullImage ?? shot.preview ?? shot.thumbnail {
                        Image(uiImage: image)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .scaleEffect(zoom)
                            .offset(offset)
                            .frame(width: geo.size.width, height: geo.size.height)
                            .clipped()
                            .gesture(pinch)
                            .simultaneousGesture(pan)
                            .onTapGesture(count: 2) { toggleZoom() }
                    } else {
                        ProgressView().tint(Theme.dim)
                    }
                } else {
                    VStack(spacing: 10) {
                        Image(systemName: "camera.aperture")
                            .font(.system(size: 34, weight: .ultraLight))
                            .foregroundStyle(Theme.dimmer)
                        Text(emptyMessage)
                            .font(.system(size: 14))
                            .foregroundStyle(Theme.dim)
                            .multilineTextAlignment(.center)
                    }
                    .padding(.horizontal, 24)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onChange(of: session.selection) { _, _ in
            zoom = 1; offset = .zero; offsetAtStart = .zero
            fullImage = nil
            if let shot { session.requestPreview(for: shot) }
            if let url = shot?.localURL { loadFull(url) }
        }
        // 取り込みが済んだら、端末内のファイルから大きな絵を作り直す
        .onChange(of: shot?.localURL) { _, url in
            if let url { loadFull(url) }
        }
        .onAppear {
            if let shot { session.requestPreview(for: shot) }
        }
    }

    private var emptyMessage: String {
        guard session.isConnected else { return String(localized: "カメラを USB で接続してください") }
        if session.browsingCard {
            return session.catalogReady
                ? String(localized: "カードに写真がありません")
                : String(localized: "カードを読み込んでいます…")
        }
        return String(localized: "シャッターを押すと、ここに表示されます")
    }

    private var pinch: some Gesture {
        MagnifyGesture()
            .onChanged { zoom = min(max($0.magnification, 1), 8) }
            .onEnded { _ in if zoom <= 1.02 { withAnimation { offset = .zero } } }
    }

    private var pan: some Gesture {
        DragGesture()
            .onChanged { v in
                guard zoom > 1.02 else { return }
                offset = CGSize(width: offsetAtStart.width + v.translation.width,
                                height: offsetAtStart.height + v.translation.height)
            }
            .onEnded { _ in offsetAtStart = offset }
    }

    private func toggleZoom() {
        withAnimation(.easeOut(duration: 0.2)) {
            if zoom > 1.02 { zoom = 1; offset = .zero } else { zoom = 3 }
        }
        offsetAtStart = offset
    }

    /// NEF に埋め込まれた JPEG から表示用の画像を作る。
    /// RAW を展開すると桁違いに遅いので、埋め込みを使う。
    private func loadFull(_ url: URL) {
        Task {
            if let image = await Preview.load(url) { fullImage = image }
        }
    }
}

/// 写真のすぐ下の段。左にファイル名（ライブビュー中は映像の状態）、右にライブビュー・全画面・取り込み
struct PreviewInfoRow: View {
    @EnvironmentObject var session: CameraSession
    @Environment(\.openReview) private var openReview
    @ObservedObject var live: LiveViewController
    let openLiveFullScreen: () -> Void

    private var shot: Shot? {
        session.shots.first { $0.id == session.selection } ?? session.shots.first
    }

    var body: some View {
        HStack(spacing: 0) {
            if live.state != .off {
                LiveStatus(feed: live.feed, state: live.state, shooting: live.suspended, autoStopIn: live.autoStopIn)
            } else if let shot {
                HStack(spacing: 6) {
                    Text(shot.name)
                        .font(.system(size: 13, weight: .medium))
                    Text(shot.sizeText)
                        .font(.system(size: 12).monospacedDigit())
                        .foregroundStyle(Theme.dim)
                    if shot.location != nil {
                        Image(systemName: "location.fill")
                            .font(.system(size: 9))
                            .foregroundStyle(Theme.dim)
                            .accessibilityLabel(Text("位置情報"))
                    }
                }
                .lineLimit(1)
            }

            Spacer(minLength: 8)

            LiveViewToggle(live: live)

            if live.state != .off || shot != nil {
                IconButton(systemName: "arrow.up.left.and.arrow.down.right", label: Text("全画面")) {
                    live.state == .off ? openReview() : openLiveFullScreen()
                }
            }

            if live.state == .off, let shot {
                ImportButton(shot: shot)
                    .padding(.leading, 4)
            }
        }
        .padding(.leading, 14)
        .padding(.trailing, 10)
        .frame(height: 50)
    }

}

/// 取り込みボタン。押すとカプセルの中が琥珀色で満ちていき、満ちきったら「保存済み」の表示に変わる。
///
/// 進み具合は ImageCaptureCore のダウンロードが返す Progress から取る。
/// 数字が届かない間（届かない機種もある）は、光の帯を流して動いていることだけを伝える
struct ImportButton: View {
    @EnvironmentObject var session: CameraSession
    let shot: Shot

    var body: some View {
        let progress = session.importProgress[shot.name]
        let done = shot.localURL != nil && progress == nil

        Button(action: start) {
            HStack(spacing: 5) {
                Image(systemName: done ? "checkmark.circle.fill" : "arrow.down.to.line")
                    .contentTransition(.symbolEffect(.replace))
                Text(label(progress: progress, done: done))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(progress != nil ? Theme.text : Theme.amber)
            .padding(.horizontal, 12)
            .frame(width: 118, height: 36)
            .background {
                if let progress { ImportFill(progress: progress) }
            }
            .glassCapsule(active: !done)
            .frame(height: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // disabled にすると済んだ表示まで薄くなるので、触れないようにだけする
        .allowsHitTesting(progress == nil && !done)
        .accessibilityAddTraits(done ? .isStaticText : [])
        .animation(.snappy(duration: 0.3), value: done)
        .animation(.snappy(duration: 0.2), value: progress == nil)
    }

    private func label(progress: Double?, done: Bool) -> String {
        if done { return shot.savedToPhotos ? String(localized: "保存済み") : String(localized: "取り込み済み") }
        if progress != nil { return String(localized: "取り込み中") }
        return String(localized: "取り込む")
    }

    private func start() {
        Task {
            if await session.importShot(shot) != nil { Haptics.success() }
        }
    }
}

/// 取り込み中のカプセルの中身
private struct ImportFill: View {
    let progress: Double

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                if progress > 0 {
                    Rectangle()
                        .fill(Theme.amber.opacity(0.45))
                        .frame(width: geo.size.width * min(progress, 1))
                        .animation(.easeOut(duration: 0.25), value: progress)
                } else {
                    // まだ数字が届いていない。光の帯を左から右へ流す
                    TimelineView(.animation) { timeline in
                        let t = timeline.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.1) / 1.1
                        LinearGradient(colors: [.clear, Theme.amber.opacity(0.5), .clear],
                                       startPoint: .leading, endPoint: .trailing)
                            .frame(width: geo.size.width * 0.5)
                            .offset(x: geo.size.width * (1.5 * t - 0.5))
                    }
                }
            }
        }
        .clipShape(Capsule())
    }
}

// MARK: - コマの一覧

/// テザーとカードの切り替えと、コマの並び。1 行にまとめる
struct ShotStrip: View {
    @EnvironmentObject var session: CameraSession

    var body: some View {
        HStack(spacing: 10) {
            SourceToggle()
                .padding(.leading, 14)

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 6) {
                    ForEach(session.shots) { shot in
                        Thumbnail(image: shot.thumbnail, located: shot.location != nil,
                                  imported: shot.localURL != nil, selected: shot.id == session.selection)
                            .onTapGesture {
                                guard session.selection != shot.id else { return }
                                Haptics.select()
                                session.selection = shot.id
                            }
                            .onAppear { session.requestThumbnail(for: shot) }
                    }
                }
                .padding(.vertical, 4)
                .padding(.trailing, 14)
            }
        }
        .frame(height: 56)
    }
}

/// コマ 1 枚。表示に使う値だけを受け取る
private struct Thumbnail: View {
    let image: UIImage?
    /// 撮影地点を付けられる
    let located: Bool
    let imported: Bool
    let selected: Bool

    var body: some View {
        ZStack {
            if let image {
                Image(uiImage: image).resizable().aspectRatio(contentMode: .fill)
            } else {
                Rectangle().fill(Theme.surfaceRaised)
                ProgressView().controlSize(.mini).tint(Theme.dim)
            }
        }
        .frame(width: 66, height: 44)
        .overlay(alignment: .topTrailing) {
            if located {
                Image(systemName: "location.fill")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.6), radius: 1.5)
                    .padding(3)
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if imported {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.onAmber, Theme.amber)
                    .padding(2)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 5))
        .overlay(
            RoundedRectangle(cornerRadius: 5)
                .strokeBorder(selected ? Theme.amber : .clear, lineWidth: 2)
        )
        .contentShape(Rectangle())
    }
}

/// テザー撮影ぶんとカード内を切り替える。
/// 既定はテザー。接続後に撮ったカットだけを出す（Mac 版と同じ考え方）。
/// 標準のセグメントにして、iOS 26 では選択中が Liquid Glass になるようにする
struct SourceToggle: View {
    @EnvironmentObject var session: CameraSession

    var body: some View {
        Picker("", selection: Binding(
            get: { session.browsingCard },
            set: {
                guard $0 != session.browsingCard else { return }
                Haptics.select()
                session.browsingCard = $0
            }
        )) {
            Text("テザー \(session.liveShots.count)").tag(false)
            Text(cardLabel).tag(true)
        }
        .pickerStyle(.segmented)
        .fixedSize()
        .disabled(!session.isConnected)
    }

    private var cardLabel: String {
        session.catalogReady || !session.isConnected
            ? String(localized: "カード \(session.cardShots.count)")
            : String(localized: "カード \(session.catalogProgress)%")
    }
}

// MARK: - 操作パネル

struct ControlPanel: View {
    @EnvironmentObject var session: CameraSession

    /// スクラバーは撮影モードで 2〜3 本に変わる。そのたびにシャッターが上下しないよう、3 本ぶんの高さを取っておく
    private static let scrubberRows: CGFloat = 3 * 44 + 2 * 6

    var body: some View {
        VStack(spacing: 8) {
            ExposureReadout()
                .frame(height: 24)

            VStack(spacing: 6) {
                ForEach(session.adjustable, id: \.self) { prop in
                    if let desc = session.props[prop] {
                        ScrubberControl(
                            title: prop.label,
                            options: desc.choiceTexts,
                            selectedIndex: desc.choices.firstIndex(of: desc.current) ?? 0,
                            enabled: desc.writable,
                            onSelect: { index in
                                await session.setProp(prop, to: desc.choices[index])
                            }
                        )
                    }
                }
            }
            .frame(height: session.isConnected ? Self.scrubberRows : nil, alignment: .top)

            HStack(spacing: 0) {
                Group {
                    if let mode = session.props[.exposureProgram], !mode.choices.isEmpty {
                        // 選択肢はカメラが申告したものをそのまま出す。
                        // 機種によって並びも項目数も違うため決め打ちにしない。
                        ModeSelector(desc: mode) { value in
                            await session.setProp(.exposureProgram, to: value)
                        }
                    } else if let mode = session.props[.exposureProgram] {
                        Text(mode.currentText)
                            .font(.system(size: 14, weight: .semibold, design: .rounded))
                            .foregroundStyle(Theme.dim)
                            .frame(width: 36, height: 36)
                            .background(Theme.surface, in: Circle())
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                ShutterButton(busy: session.busy, enabled: session.isConnected) {
                    Haptics.shutter()
                    Task { await session.capture() }
                }

                WhiteBalanceMenu()
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .frame(height: 80)
        }
        .padding(.horizontal, 14)
        .padding(.top, 6)
    }
}

/// スクラバーの上の 1 行。撮影モードに応じて、カメラ任せの値か露出計を出す
struct ExposureReadout: View {
    @EnvironmentObject var session: CameraSession

    var body: some View {
        HStack(spacing: 14) {
            if session.cannotAdjustSettings {
                Label("この機種は USB から設定を変えられません。露出や ISO は本体で設定してください。", systemImage: "info.circle")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.dim)
                    .lineLimit(2)
                    .minimumScaleFactor(0.8)
            } else if session.lightMeterMeaningful {
                Text("露出計")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.dim)
                LightMeterView(value: session.lightMeter)
            } else if !session.cameraDecided.isEmpty {
                ForEach(session.cameraDecided, id: \.self) { prop in
                    if let desc = session.props[prop] {
                        HStack(spacing: 5) {
                            Text(prop.label)
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(Theme.dim)
                            Text(desc.currentText)
                                .font(.system(size: 14, weight: .semibold, design: .rounded).monospacedDigit())
                                .contentTransition(.numericText())
                                .animation(.snappy(duration: 0.18), value: desc.current)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
    }
}

/// カメラの露出計をそのまま可視化する。
/// 中央が適正。Nikon の慣習に合わせ、左が＋（露出過多）、右が−（露出不足）。
/// Canon とは左右が逆になる。
struct LightMeterView: View {
    let value: Double?

    var body: some View {
        let ev = max(-3, min(3, value ?? 0))
        HStack(spacing: 6) {
            Text("+").font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.dim)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    HStack(spacing: 0) {
                        ForEach(0..<13) { i in
                            Rectangle()
                                .fill(i == 6 ? Theme.dim : Theme.dimmer.opacity(i % 2 == 0 ? 1 : 0.6))
                                .frame(width: 1, height: i == 6 ? 14 : (i % 2 == 0 ? 9 : 5))
                            if i < 12 { Spacer(minLength: 0) }
                        }
                    }
                    .frame(height: 16)

                    if value != nil {
                        Capsule()
                            .fill(Theme.amber)
                            .frame(width: 3, height: 16)
                            .offset(x: (geo.size.width - 3) * ((3 - ev) / 6))
                            .animation(.easeOut(duration: 0.15), value: ev)
                    }
                }
                .frame(height: 16)
            }
            .frame(maxWidth: 170)
            .frame(height: 16)
            Text("−").font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.dim)
            Text(value.map { abs($0) < 0.05 ? "±0" : String(format: "%+.1f", $0) } ?? "—")
                .font(.system(size: 13, weight: .semibold, design: .rounded).monospacedDigit())
                .foregroundStyle(value.map { abs($0) < 0.2 } == true ? Theme.amber : Theme.text)
                .frame(width: 36, alignment: .trailing)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("露出計"))
        .accessibilityValue(Text(value.map { String(format: "%+.1f EV", $0) } ?? "—"))
    }
}

/// 白バランス。ボタンには今の設定のアイコンだけを出し、名前はメニューの中で読む。
///
/// 以前はボタンに「電球」「晴天」などの文字を載せていて、横に並ぶ部品に押されて潰れていた。
struct WhiteBalanceMenu: View {
    @EnvironmentObject var session: CameraSession
    @State private var pending: Int64?
    @State private var generation = 0

    var body: some View {
        if let wb = session.props[.whiteBalance], !wb.choices.isEmpty {
            let shown = pending ?? wb.current
            Menu {
                // メニューの中は標準のピッカーにして、選択中に印が付くようにする
                Picker("", selection: Binding(get: { shown }, set: { select($0, from: wb) })) {
                    ForEach(wb.choices, id: \.self) { value in
                        Label(PropFormat.text(.whiteBalance, value),
                              systemImage: PropFormat.whiteBalanceSymbol(value))
                            .tag(value)
                    }
                }
                .pickerStyle(.inline)
            } label: {
                Image(systemName: PropFormat.whiteBalanceSymbol(shown))
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(Theme.text)
                    .frame(width: 44, height: 44)
                    .glassCircle()
                    .contentTransition(.symbolEffect(.replace))
            }
            .accessibilityLabel(Text("白バランス: \(PropFormat.text(.whiteBalance, shown))"))
            .disabled(!wb.writable)
            .opacity(wb.writable ? 1 : 0.5)
        }
    }

    private func select(_ value: Int64, from wb: PropDesc) {
        guard value != (pending ?? wb.current) else { return }
        Haptics.select()
        pending = value
        generation += 1
        let mine = generation
        Task { @MainActor in
            let accepted = await session.setProp(.whiteBalance, to: value)
            guard mine == generation else { return }
            pending = nil
            if !accepted { Haptics.warning() }
        }
    }
}

/// 撮影モードの切り替え。標準のセグメントで、選択中のガラスが正円になる幅に固定する。
///
/// iOS 26 の標準セグメントは、本体の高さが 32 で、選択中のガラス（_UILiquidLensView）が
/// 上下左右に 2 ずつ内側に描かれる。ガラスの高さは幅によらず 28 なので、区画の幅を 32 にすると
/// 28×28 の正円になる（シミュレータで幅 120〜170 の実寸を読んで確認）。
///
/// スクラバーと同じく、押した瞬間にその区画を選んだ状態にしてカメラの返事を待つ。
struct ModeSelector: View {
    let desc: PropDesc
    let onSelect: (Int64) async -> Bool

    @State private var pending: Int64?
    @State private var generation = 0

    private static let segmentWidth: CGFloat = 32

    var body: some View {
        let labels = desc.choices.map { PropFormat.text(.exposureProgram, $0) }
        // 機種独自の長い名前があるときは正円にこだわらず、文字が収まる幅に任せる
        let fitsCircle = labels.allSatisfy { $0.count <= 2 }

        Picker("", selection: Binding(
            get: { pending ?? desc.current },
            set: { select($0) }
        )) {
            ForEach(Array(zip(desc.choices, labels)), id: \.0) { value, label in
                Text(label).tag(value)
            }
        }
        .pickerStyle(.segmented)
        .frame(width: fitsCircle ? CGFloat(desc.choices.count) * Self.segmentWidth : nil)
        // 横に並ぶ他の部品に押されて縮むと、また楕円になる
        .fixedSize()
        .disabled(!desc.writable)
    }

    private func select(_ value: Int64) {
        guard value != (pending ?? desc.current) else { return }
        Haptics.select()
        pending = value
        generation += 1
        let mine = generation
        Task { @MainActor in
            let accepted = await onSelect(value)
            guard mine == generation else { return }
            pending = nil
            if !accepted { Haptics.warning() }
        }
    }
}
