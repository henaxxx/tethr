import SwiftUI
import ImageIO
import UniformTypeIdentifiers

struct ContentView: View {
    @EnvironmentObject var session: CameraSession
    @State private var reviewing = false
    /// 起動した最初の画面から待ち画面を出しておく。通常の画面が一瞬見えてから切り替わらないように
    @State private var showPreparing = true
    @State private var preparingReveal: Date?
    /// 起動直後、つながっているカメラが見つかるまでの猶予。見つからなければ待ち画面を閉じる
    @State private var launching = true

    var body: some View {
        VStack(spacing: 0) {
            StatusHeader()
            Divider()
            PreviewArea()
            Divider()
            SourcePicker()
            Filmstrip()
                .frame(height: 92)
            Divider()
            ControlPanel()
        }
        .background(Color(uiColor: .systemBackground))
        .alert("エラー", isPresented: Binding(
            get: { session.lastError != nil },
            set: { if !$0 { session.lastError = nil } }
        )) {
            Button("OK") { session.lastError = nil }
        } message: {
            Text(session.lastError ?? "")
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

struct StatusHeader: View {
    @EnvironmentObject var session: CameraSession

    var body: some View {
        HStack(spacing: 10) {
            if session.preparing {
                // 固まっているのではなく待っていると分かるように回しておく
                ProgressView().controlSize(.mini)
            } else {
                Circle().fill(color).frame(width: 8, height: 8)
            }
            Text(text).font(.system(size: 12, weight: .medium)).lineLimit(1)
            Spacer(minLength: 6)
            if session.isConnected {
                // M 以外では振れないので、場所は残したまま透明にする（ヘッダーの他の表示をずらさない）
                LightMeterView(value: session.lightMeter)
                    .opacity(session.lightMeterMeaningful ? 1 : 0)
                    .animation(.easeInOut(duration: 0.4), value: session.lightMeterMeaningful)
                    .accessibilityHidden(!session.lightMeterMeaningful)
            }
            Spacer(minLength: 6)
            if let drift = session.clockCorrection, abs(drift) > 2 {
                Image(systemName: "clock.arrow.trianglehead.counterclockwise.rotate.90")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .help("カメラの時計を \(Int(abs(drift))) 秒ぶん合わせました")
            }
            if let battery = session.props[.batteryLevel] {
                Text(battery.currentText)
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private var color: Color {
        switch session.state {
        case .connected: return .green
        case .connecting, .searching: return .orange
        case .failed, .unauthorized: return .red
        case .idle: return .secondary
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

/// テザー撮影ぶんとカード内を切り替える。
/// 既定はテザー。接続後に撮ったカットだけを出す（Mac 版と同じ考え方）。
struct SourcePicker: View {
    @EnvironmentObject var session: CameraSession

    var body: some View {
        HStack(spacing: 10) {
            Picker("", selection: Binding(
                get: { session.browsingCard },
                set: { session.browsingCard = $0 }
            )) {
                Text("テザー (\(session.liveShots.count))").tag(false)
                Text(cardLabel).tag(true)
            }
            .pickerStyle(.segmented)
            .disabled(!session.isConnected)
        }
        .padding(.horizontal, 14)
        .padding(.top, 8)
    }

    private var cardLabel: String {
        session.catalogReady
            ? String(localized: "カード (\(session.cardShots.count))")
            : String(localized: "カード 読込中 \(session.catalogProgress)%")
    }
}

/// カメラの露出計をそのまま可視化する。
/// 中央が適正。Nikon の慣習に合わせ、左が＋（露出過多）、右が−（露出不足）。
/// Canon とは左右が逆になる。
struct LightMeterView: View {
    let value: Double?

    var body: some View {
        let ev = max(-3, min(3, value ?? 0))
        HStack(spacing: 5) {
            Text("＋").font(.system(size: 9)).foregroundStyle(.tertiary)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    HStack(spacing: 0) {
                        ForEach(0..<13) { i in
                            Rectangle()
                                .fill(Color.secondary.opacity(i % 2 == 0 ? 0.5 : 0.22))
                                .frame(width: 1, height: i == 6 ? 11 : (i % 2 == 0 ? 7 : 4))
                            if i < 12 { Spacer(minLength: 0) }
                        }
                    }
                    .frame(height: 11)

                    if value != nil {
                        Capsule()
                            .fill(abs(ev) < 0.2 ? Color.green : Color.orange)
                            .frame(width: 3, height: 13)
                            .offset(x: (geo.size.width - 3) * ((3 - ev) / 6))
                            .animation(.easeOut(duration: 0.15), value: ev)
                    }
                }
                .frame(height: 13)
            }
            .frame(width: 116, height: 13)
            Text("−").font(.system(size: 9)).foregroundStyle(.tertiary)
            Text(value.map { String(format: "%+.1f", $0) } ?? "—")
                .font(.system(size: 10).monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 30, alignment: .leading)
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

struct PreviewArea: View {
    @EnvironmentObject var session: CameraSession
    @Environment(\.openReview) private var openReview
    @State private var zoom: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var offsetAtStart: CGSize = .zero
    @State private var fullImage: UIImage?
    @State private var downloading = false

    private var shot: Shot? {
        session.shots.first { $0.id == session.selection } ?? session.shots.first
    }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color(uiColor: .secondarySystemBackground).opacity(0.4)

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
                        ProgressView()
                    }

                    VStack {
                        Spacer()
                        HStack(spacing: 10) {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(shot.name).font(.system(size: 12, weight: .medium))
                                Text(shot.sizeText).font(.system(size: 10)).foregroundStyle(.secondary)
                            }
                            Button { openReview() } label: {
                                Image(systemName: "arrow.up.left.and.arrow.down.right")
                                    .font(.system(size: 14, weight: .medium))
                            }
                            .padding(.leading, 4)
                            Spacer()
                            if downloading {
                                ProgressView().controlSize(.small)
                            } else if shot.localURL == nil {
                                Button("端末に取り込む") { download(shot) }
                                    .font(.system(size: 12, weight: .medium))
                                    .buttonStyle(.borderedProminent)
                                    .controlSize(.small)
                            } else {
                                Label(shot.savedToPhotos ? "写真アプリに保存済み" : "取り込み済み",
                                      systemImage: "checkmark.circle.fill")
                                    .font(.system(size: 11)).foregroundStyle(.green)
                            }
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(.ultraThinMaterial)
                    }
                } else {
                    VStack(spacing: 8) {
                        Image(systemName: "camera.macro")
                            .font(.system(size: 34, weight: .ultraLight))
                            .foregroundStyle(.tertiary)
                        Text(emptyMessage)
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
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

    private func download(_ shot: Shot) {
        downloading = true
        Task {
            let url = await session.importShot(shot)
            downloading = false
            guard let url else { return }
            loadFull(url)
        }
    }

    /// NEF に埋め込まれた JPEG から表示用の画像を作る。
    /// RAW を展開すると桁違いに遅いので、埋め込みを使う。
    private func loadFull(_ url: URL) {
        Task.detached(priority: .userInitiated) {
            guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return }
            let opts: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageIfAbsent: true,
                kCGImageSourceThumbnailMaxPixelSize: 2400,
                kCGImageSourceCreateThumbnailWithTransform: true,
            ]
            guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return }
            let image = UIImage(cgImage: cg)
            await MainActor.run { self.fullImage = image }
        }
    }
}

// MARK: - フィルムストリップ

struct Filmstrip: View {
    @EnvironmentObject var session: CameraSession

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(spacing: 6) {
                ForEach(session.shots) { shot in
                    ZStack {
                        if let t = shot.thumbnail {
                            Image(uiImage: t).resizable().aspectRatio(contentMode: .fill)
                        } else {
                            Rectangle().fill(Color(uiColor: .tertiarySystemBackground))
                            ProgressView().controlSize(.small)
                        }
                        VStack {
                            HStack(spacing: 2) {
                                Spacer()
                                if shot.location != nil {
                                    Image(systemName: "location.fill")
                                        .font(.system(size: 9))
                                        .foregroundStyle(.white.opacity(0.85))
                                }
                                if shot.localURL != nil {
                                    Image(systemName: "checkmark.circle.fill")
                                        .font(.system(size: 11))
                                        .foregroundStyle(.green)
                                }
                            }
                            .padding(3)
                            Spacer()
                        }
                    }
                    .frame(width: 104, height: 70)
                    .clipped()
                    .clipShape(RoundedRectangle(cornerRadius: 5))
                    .overlay(
                        RoundedRectangle(cornerRadius: 5)
                            .strokeBorder(shot.id == session.selection ? Color.accentColor : .clear, lineWidth: 2)
                    )
                    .onTapGesture { session.selection = shot.id }
                    .onAppear { session.requestThumbnail(for: shot) }
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 10)
        }
    }
}

/// ホワイトバランス。選択肢が少なく触る頻度も低いので、
/// スクラバーを増やさずプルダウンに収める。
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
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.primary)
                    .frame(width: 32, height: 32)
                    .background(Color(uiColor: .tertiarySystemFill), in: Circle())
                    .contentTransition(.symbolEffect(.replace))
            }
            .accessibilityLabel(Text("白バランス: \(PropFormat.text(.whiteBalance, shown))"))
            .disabled(!wb.writable)
            .opacity(wb.writable ? 1 : 0.5)
        }
    }

    private func select(_ value: Int64, from wb: PropDesc) {
        guard value != (pending ?? wb.current) else { return }
        pending = value
        generation += 1
        let mine = generation
        Task { @MainActor in
            let accepted = await session.setProp(.whiteBalance, to: value)
            guard mine == generation else { return }
            pending = nil
            if !accepted { UINotificationFeedbackGenerator().notificationOccurred(.warning) }
        }
    }
}

// MARK: - 操作パネル

struct ControlPanel: View {
    @EnvironmentObject var session: CameraSession
    @State private var showGeoPanel = false

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                if let mode = session.props[.exposureProgram], !mode.choices.isEmpty {
                    // 選択肢はカメラが申告したものをそのまま出す。
                    // 機種によって並びも項目数も違うため決め打ちにしない。
                    ModeSelector(desc: mode) { value in
                        await session.setProp(.exposureProgram, to: value)
                    }
                } else if let mode = session.props[.exposureProgram] {
                    Text(mode.currentText)
                        .font(.system(size: 12, weight: .bold, design: .rounded))
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(Color(uiColor: .tertiarySystemBackground),
                                    in: RoundedRectangle(cornerRadius: 5))
                }
                if let bias = session.props[.exposureBias] {
                    Text(bias.currentText)
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                WhiteBalanceMenu()
                Button {
                    showGeoPanel = true
                } label: {
                    Image(systemName: session.geotagging ? "location.fill" : "location.slash")
                        .font(.system(size: 12))
                        .foregroundStyle(session.geotagging ? Color.accentColor : .secondary)
                }
                .help("位置情報")
                Spacer(minLength: 4)
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
                    .frame(width: 54, height: 54)
                }
                .buttonStyle(.borderedProminent)
                .clipShape(Circle())
                .disabled(!session.isConnected || session.busy)
            }

            ForEach(session.adjustable, id: \.self) { prop in
                if let desc = session.props[prop], !desc.choices.isEmpty {
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
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .sheet(isPresented: $showGeoPanel) {
            GeoPanel().environmentObject(session)
        }
    }
}


/// 撮影モードの切り替え。標準のセグメントで、選択中のガラスが正円になる幅に固定する。
///
/// iOS 26 の標準セグメントは、本体の高さが 32 で、選択中のガラス（_UILiquidLensView）が
/// 上下左右に 2 ずつ内側に描かれる。ガラスの高さは幅によらず 28 なので、区画の幅を 32 にすると
/// 28×28 の正円になる（シミュレータで幅 120〜170 の実寸を読んで確認）。
/// 以前は幅 150 に押し込んでいたため、ガラスが 33.5×28 の楕円になっていた。
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
        pending = value
        generation += 1
        let mine = generation
        Task { @MainActor in
            let accepted = await onSelect(value)
            guard mine == generation else { return }
            pending = nil
            if !accepted { UINotificationFeedbackGenerator().notificationOccurred(.warning) }
        }
    }
}
