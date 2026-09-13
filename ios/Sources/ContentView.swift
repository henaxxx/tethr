import SwiftUI
import ImageIO
import UniformTypeIdentifiers

struct ContentView: View {
    @EnvironmentObject var session: CameraSession
    @State private var reviewing = false

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
        .task {
            if case .idle = session.state { session.start() }
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
                LightMeterView(value: session.lightMeter)
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
struct WhiteBalanceMenu: View {
    @EnvironmentObject var session: CameraSession

    var body: some View {
        if let wb = session.props[.whiteBalance], !wb.choices.isEmpty {
            Menu {
                ForEach(wb.choices, id: \.self) { value in
                    Button {
                        Task { await session.setProp(.whiteBalance, to: value) }
                    } label: {
                        if value == wb.current {
                            Label(PropFormat.text(.whiteBalance, value), systemImage: "checkmark")
                        } else {
                            Text(PropFormat.text(.whiteBalance, value))
                        }
                    }
                }
            } label: {
                HStack(spacing: 3) {
                    Image(systemName: "circle.lefthalf.filled").font(.system(size: 10))
                    Text(wb.currentText).font(.system(size: 11, weight: .medium))
                    Image(systemName: "chevron.down").font(.system(size: 7, weight: .bold))
                }
                .foregroundStyle(.primary)
                .padding(.horizontal, 7)
                .padding(.vertical, 4)
                .background(Color(uiColor: .tertiarySystemBackground),
                            in: RoundedRectangle(cornerRadius: 5))
            }
            .disabled(!wb.writable)
            .opacity(wb.writable ? 1 : 0.5)
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
                    Picker("", selection: Binding(
                        get: { mode.current },
                        set: { newValue in Task { await session.setProp(.exposureProgram, to: newValue) } }
                    )) {
                        ForEach(mode.choices, id: \.self) { value in
                            Text(PropFormat.text(.exposureProgram, value)).tag(value)
                        }
                    }
                    .pickerStyle(.segmented)
                    .disabled(!mode.writable)
                    .frame(maxWidth: 150)
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

            ForEach(CameraSession.adjustable, id: \.self) { prop in
                if let desc = session.props[prop], !desc.choices.isEmpty {
                    ScrubberControl(
                        title: prop.label,
                        options: desc.choiceTexts,
                        selectedIndex: desc.choices.firstIndex(of: desc.current) ?? 0,
                        enabled: desc.writable,
                        onSelect: { index in
                            Task { await session.setProp(prop, to: desc.choices[index]) }
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
