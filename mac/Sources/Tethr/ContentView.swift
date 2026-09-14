import SwiftUI
import TethrKit
import TethrUI

/// 撮影の画面。写真が主役で、操作は右のパネルに寄せる。
///
/// iOS 版と同じく、暗いグレーに琥珀色を 1 色だけ置き、写真の上には何も重ねない。
/// ファイル名や拡大操作は写真の下の行に、露出の操作とシャッターは右パネルに置く
struct ContentView: View {
    @EnvironmentObject var model: SessionModel
    @StateObject private var zoom = PreviewZoom()
    @State private var showInspector = true

    var body: some View {
        VStack(spacing: 0) {
            if model.destinationProblem != nil || !model.failedTransfers.isEmpty {
                DestinationWarning()
            }
            MainArea(card: model.card, geo: model.geo, zoom: zoom)
        }
        .background(Theme.background)
        .foregroundStyle(Theme.text)
        .inspector(isPresented: $showInspector) {
            ShootingInspector()
                .inspectorColumnWidth(min: 280, ideal: 310, max: 380)
        }
        .toolbar {
            ToolbarItem(placement: .navigation) {
                CameraMenu()
            }
            ToolbarItemGroup(placement: .principal) {
                LiveViewButton()
                AutofocusButton()
            }
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    NSWorkspace.shared.open(model.effectiveDestination)
                } label: {
                    Label(model.effectiveDestination.lastPathComponent, systemImage: "folder")
                        .labelStyle(.titleAndIcon)
                }
                .help(model.effectiveDestination.path)

                Button { showInspector.toggle() } label: {
                    Label("撮影設定", systemImage: "sidebar.trailing")
                }
                .help("撮影設定パネル")
            }
        }
        // スペースキーでシャッター。右パネルを閉じていても効くよう、画面全体に持たせる
        .background {
            Button("") { model.shoot() }
                .keyboardShortcut(.space, modifiers: [])
                .disabled(!model.isConnected || model.busy)
                .hidden()
        }
        .alert("エラー", isPresented: Binding(
            get: { model.lastError != nil },
            set: { if !$0 { model.lastError = nil } }
        )) {
            Button("OK") { model.lastError = nil }
        } message: {
            Text(model.lastError ?? "")
        }
    }
}

/// 写真の欄と下の段。テザーの一覧とカードの一覧を切り替える
private struct MainArea: View {
    @EnvironmentObject var model: SessionModel
    @ObservedObject var card: CardModel
    @ObservedObject var geo: GeoStore
    @ObservedObject var zoom: PreviewZoom

    var body: some View {
        if card.active && model.isConnected {
            CardBrowser(card: card)
            CardInfoRow(card: card)
            CardActionBar(card: card, geo: geo)
        } else {
            PreviewPane(zoom: zoom)
            PreviewInfoRow(zoom: zoom)
            Filmstrip()
        }
    }
}

/// 保存先が書けない、または転送に失敗したコマがあることを知らせる帯。
/// 撮影中に見落とすと取り返しがつかないので、常時見える位置に出す。
struct DestinationWarning: View {
    @EnvironmentObject var model: SessionModel

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Theme.amber)
            VStack(alignment: .leading, spacing: 2) {
                if let problem = model.destinationProblem {
                    Text(problem).font(.system(size: 12, weight: .medium))
                }
                if !model.failedTransfers.isEmpty {
                    Text("転送できなかったコマ: \(model.failedTransfers.joined(separator: ", "))  — カメラのカードには残っています")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.dim)
                        .lineLimit(2)
                }
            }
            Spacer()
            Button("再確認") { model.clearFailedTransfers() }
                .controlSize(.small)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Theme.amber.opacity(0.14))
    }
}

// MARK: - ツールバー

/// 機種名。押すとファームウェア・時計・電池と、めったに使わない操作（切断など）が並ぶ
struct CameraMenu: View {
    @EnvironmentObject var model: SessionModel

    var body: some View {
        Menu {
            if model.isConnected {
                Section {
                    if let info = model.deviceInfo {
                        if !info.version.isEmpty { Text("ファームウェア \(info.version)") }
                        if !info.serialNumber.isEmpty { Text("S/N \(info.serialNumber)") }
                    }
                    if let focal = model.currentFocalLength {
                        Text("焦点距離 \(focal)")
                    }
                    if let battery = model.batteryPercent {
                        Text("カメラの電池 \(BatteryIcon.rangeText(battery))")
                    }
                    if let clock = model.clockOffsetDescription {
                        Text("カメラの時計: \(clock)")
                    }
                }
                Section {
                    Button("時計を Mac に合わせる") { model.syncClock() }
                    Button("本体の操作を戻す") { model.releaseCameraControl() }
                }
                Section {
                    Button("切断") { model.disconnect() }
                }
            } else if model.isWaiting {
                Text(statusText)
                Button("待つのをやめる") { model.disconnect() }
            } else {
                Button("接続") { model.connect() }
            }
        } label: {
            // ツールバーのメニューは図形を落として文字だけ描くので、点も文字の一部として埋め込む
            let dot = Text(Image(systemName: model.isWaiting ? "circle.dotted" : "circle.fill"))
                .font(.system(size: 7))
                .foregroundStyle(dotColor)
            Text("\(dot)  \(statusText)")
                .font(.system(size: 13, weight: model.isConnected ? .semibold : .regular))
                .lineLimit(1)
        }
        .menuIndicator(.visible)
        .fixedSize()
        .help(detail ?? "")
    }

    /// つながらない理由。ツールバーには短く出し、詳しくはここと写真の欄に出す
    private var detail: String? {
        switch model.state {
        case .failed(let message): return message
        case .waiting: return String(localized: "USB でつないで、カメラの電源を入れてください。見つかると自動でつながります")
        case .connecting: return String(localized: "電源を入れた直後は、つながるまで 1 分ほどかかることがあります")
        default: return nil
        }
    }

    private var dotColor: Color {
        switch model.state {
        case .connected, .connecting: return Theme.amber
        case .failed: return Theme.danger
        case .waiting, .disconnected: return Theme.dimmer
        }
    }

    private var statusText: String {
        switch model.state {
        case .connected(let m): return m
        case .waiting: return String(localized: "カメラを待っています")
        case .connecting:
            switch model.warmup {
            case .system(let name)?: return String(localized: "\(name) を準備中…")
            case .card?: return String(localized: "カードを確認中…")
            case nil: return String(localized: "接続中…")
            }
        case .failed, .disconnected: return String(localized: "未接続")
        }
    }
}

struct LiveViewButton: View {
    @EnvironmentObject var model: SessionModel

    var body: some View {
        Button {
            model.toggleLiveView()
        } label: {
            Label("ライブビュー", systemImage: model.isLive ? "eye.fill" : "eye")
                .labelStyle(.titleAndIcon)
                // 色を指定すると押せないときの薄さが消えるので、つながっていないときは自分で薄くする
                .foregroundStyle(model.isLive ? AnyShapeStyle(Theme.amber)
                                 : AnyShapeStyle(model.isConnected ? HierarchicalShapeStyle.primary : .tertiary))
        }
        .disabled(!model.isConnected)
        .help("ミラーアップして映像を受け取ります（⌘L）")
    }
}

struct AutofocusButton: View {
    @EnvironmentObject var model: SessionModel

    var body: some View {
        Button {
            model.autofocus()
        } label: {
            Label {
                Text("AF")
            } icon: {
                switch model.afState {
                case .running: ProgressView().controlSize(.mini)
                case .succeeded: Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.amber)
                case .failed: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.danger)
                case .idle: Image(systemName: "viewfinder.circle")
                }
            }
            .labelStyle(.titleAndIcon)
        }
        .disabled(!model.isConnected || model.afState == .running)
        .keyboardShortcut("f", modifiers: .command)
        .help(model.afFailureDetail ?? String(localized: "AF を実行（シャッター半押し相当、⌘F）"))
    }
}

// MARK: - プレビュー（拡大・パン対応）

/// 拡大の状態。写真の下の行の操作ボタンと、写真そのものの両方から触る
@MainActor
final class PreviewZoom: ObservableObject {
    /// 1 = ウィンドウにフィット
    @Published var zoom: CGFloat = 1
    @Published var offset: CGSize = .zero
    var offsetAtDragStart: CGSize = .zero
    /// フィット時の倍率（画素 1 つあたりの表示点数）。等倍表示に使う
    @Published var fit: CGFloat = 1

    var percent: Int { Int((fit * zoom * 100).rounded()) }
    var zoomedIn: Bool { zoom > 1.02 }

    func set(_ new: CGFloat) {
        let z = min(max(new, 1), 12)
        withAnimation(.easeOut(duration: 0.15)) {
            zoom = z
            if z <= 1.02 { offset = .zero }
        }
        if z <= 1.02 { offsetAtDragStart = .zero }
    }

    func reset() {
        zoom = 1
        offset = .zero
        offsetAtDragStart = .zero
    }

    func actualSize() { set(1 / max(fit, 0.0001)) }
}

struct PreviewPane: View {
    @EnvironmentObject var model: SessionModel
    @ObservedObject var zoom: PreviewZoom
    @GestureState private var pinch: CGFloat = 1

    private var selected: Shot? {
        model.shots.first { $0.id == model.selection } ?? model.shots.first
    }

    /// 拡大時はフル解像度、まだ来ていなければサムネイルで代用する
    private var image: NSImage? {
        model.fullPreview ?? selected?.thumbnail
    }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Theme.background

                if model.preparing {
                    // 電源を入れた直後は、macOS の準備とカードの下調べが終わるまで何も通らない
                    WarmupOverlay()
                } else if model.isLive {
                    if let frame = model.liveFrame {
                        Image(nsImage: frame)
                            .resizable()
                            .interpolation(.medium)
                            .aspectRatio(contentMode: .fit)
                            .padding(12)
                    } else {
                        ProgressView().controlSize(.regular)
                    }
                } else if selected != nil {
                    if let img = image {
                        let fit = fitScale(image: img, in: geo.size)
                        let effective = zoom.zoom * pinch

                        Image(nsImage: img)
                            .resizable()
                            .interpolation(.high)
                            .aspectRatio(contentMode: .fit)
                            .scaleEffect(effective)
                            .offset(clamped(zoom.offset, image: img, fit: fit, zoom: effective, view: geo.size))
                            .frame(width: geo.size.width, height: geo.size.height)
                            .clipped()
                            .contentShape(Rectangle())
                            .gesture(panGesture(image: img, fit: fit, view: geo.size))
                            .gesture(magnifyGesture)
                            .onTapGesture(coordinateSpace: .local) { location in
                                zoomToggle(at: location, image: img, fit: fit, view: geo.size)
                            }
                            .onAppear { zoom.fit = fit }
                            .onChange(of: fit) { _, value in zoom.fit = value }
                    } else {
                        ProgressView().controlSize(.regular)
                    }
                } else if case .waiting(let note) = model.state {
                    CameraWaitView(note: note)
                } else {
                    VStack(spacing: 12) {
                        Image(systemName: "camera.aperture")
                            .font(.system(size: 40, weight: .ultraLight))
                            .foregroundStyle(Theme.dimmer)
                        Text(emptyMessage)
                            .font(.system(size: 13))
                            .foregroundStyle(Theme.dim)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onChange(of: model.selection) { _, newValue in
            zoom.reset()
            model.loadFullPreview(for: newValue)
        }
    }

    private var emptyMessage: String {
        switch model.state {
        case .connected: return String(localized: "カメラのシャッターを押すと、ここに表示されます")
        case .failed(let message): return message
        case .connecting: return String(localized: "接続中…")
        case .waiting: return String(localized: "カメラを待っています")
        case .disconnected: return String(localized: "カメラを USB で接続してください")
        }
    }

    // MARK: 拡大まわり

    private func fitScale(image: NSImage, in view: CGSize) -> CGFloat {
        let w = image.size.width, h = image.size.height
        guard w > 0, h > 0 else { return 1 }
        return min(view.width / w, view.height / h)
    }

    /// クリック 1 回でフィットと等倍を往復する（Lightroom と同じ操作感）。
    /// 拡大するときは、クリックした場所が画面中央に来るように寄せる。
    /// 単に倍率だけ上げると画面中心が拡大されてしまい、
    /// 見たかった場所がフレームの外へ出ていく。
    private func zoomToggle(at point: CGPoint, image: NSImage, fit: CGFloat, view: CGSize) {
        if zoom.zoomedIn {
            withAnimation(.easeOut(duration: 0.18)) {
                zoom.zoom = 1
                zoom.offset = .zero
            }
            zoom.offsetAtDragStart = .zero
            return
        }

        let target = 1 / max(fit, 0.0001)          // 等倍
        let fitW = image.size.width * fit
        let fitH = image.size.height * fit
        guard fitW > 0, fitH > 0 else { return }

        // クリック位置が画像のどこか（中心を 0 とした割合）
        let centerX = view.width / 2 + zoom.offset.width
        let centerY = view.height / 2 + zoom.offset.height
        let nx = (point.x - centerX) / (fitW * zoom.zoom)
        let ny = (point.y - centerY) / (fitH * zoom.zoom)

        // その点が画面中央に来る位置へ動かす
        let wanted = CGSize(width: -nx * fitW * target, height: -ny * fitH * target)
        let settled = clamped(wanted, image: image, fit: fit, zoom: target, view: view)

        withAnimation(.easeOut(duration: 0.18)) {
            zoom.zoom = target
            zoom.offset = settled
        }
        zoom.offsetAtDragStart = settled
    }

    private var magnifyGesture: some Gesture {
        MagnifyGesture()
            .updating($pinch) { value, state, _ in state = value.magnification }
            .onEnded { value in zoom.set(zoom.zoom * value.magnification) }
    }

    private func panGesture(image: NSImage, fit: CGFloat, view: CGSize) -> some Gesture {
        DragGesture()
            .onChanged { value in
                guard zoom.zoomedIn else { return }
                zoom.offset = CGSize(width: zoom.offsetAtDragStart.width + value.translation.width,
                                     height: zoom.offsetAtDragStart.height + value.translation.height)
            }
            .onEnded { _ in
                zoom.offset = clamped(zoom.offset, image: image, fit: fit, zoom: zoom.zoom, view: view)
                zoom.offsetAtDragStart = zoom.offset
            }
    }

    /// 画像が画面外へ流れていかないように移動量を抑える
    private func clamped(_ o: CGSize, image: NSImage, fit: CGFloat, zoom: CGFloat, view: CGSize) -> CGSize {
        let shownW = image.size.width * fit * zoom
        let shownH = image.size.height * fit * zoom
        let maxX = max(0, (shownW - view.width) / 2)
        let maxY = max(0, (shownH - view.height) / 2)
        return CGSize(width: min(max(o.width, -maxX), maxX),
                      height: min(max(o.height, -maxY), maxY))
    }
}

/// 写真のすぐ下の段。左にファイル名と露出（ライブビュー中は映像の状態）、右に拡大の操作
struct PreviewInfoRow: View {
    @EnvironmentObject var model: SessionModel
    @ObservedObject var zoom: PreviewZoom

    private var selected: Shot? {
        model.shots.first { $0.id == model.selection } ?? model.shots.first
    }

    var body: some View {
        HStack(spacing: 10) {
            if model.isLive {
                HStack(spacing: 6) {
                    Circle().fill(Theme.live).frame(width: 7, height: 7)
                    Text("LIVE").font(.system(size: 11, weight: .bold))
                    if model.liveFPS > 0 {
                        Text("\(model.liveFPS) fps")
                            .font(.system(size: 11).monospacedDigit())
                            .foregroundStyle(Theme.dim)
                    }
                }
            } else if let shot = selected {
                Text(shot.name).font(.system(size: 12, weight: .medium))
                if !shot.meta.summary.isEmpty {
                    Text(shot.meta.summary)
                        .font(.system(size: 12).monospacedDigit())
                        .foregroundStyle(Theme.dim)
                }
                if shot.meta.pixelWidth > 0 {
                    Text("\(shot.meta.pixelWidth)×\(shot.meta.pixelHeight)")
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(Theme.dimmer)
                }
                Button {
                    model.revealInFinder(shot)
                } label: {
                    Image(systemName: "folder").font(.system(size: 11))
                }
                .buttonStyle(.borderless)
                .foregroundStyle(Theme.dim)
                .help("Finder で表示")
            }

            Spacer(minLength: 8)

            if !model.isLive, !model.preparing, selected != nil {
                ZoomControls(zoom: zoom)
            }
        }
        .lineLimit(1)
        .padding(.horizontal, 14)
        .frame(height: 40)
    }
}

private struct ZoomControls: View {
    @ObservedObject var zoom: PreviewZoom

    var body: some View {
        HStack(spacing: 2) {
            Button { zoom.set(zoom.zoom / 1.5) } label: { Image(systemName: "minus.magnifyingglass") }
                .disabled(!zoom.zoomedIn)
            Text("\(zoom.percent)%")
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(Theme.dim)
                .frame(width: 42)
            Button { zoom.set(zoom.zoom * 1.5) } label: { Image(systemName: "plus.magnifyingglass") }
            Divider().frame(height: 14)
            Button { zoom.set(1) } label: { Image(systemName: "arrow.up.left.and.arrow.down.right") }
                .help("フィット")
            Button { zoom.actualSize() } label: { Image(systemName: "1.square") }
                .help("等倍表示")
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .glassCapsule()
    }
}

// MARK: - フィルムストリップ

struct Filmstrip: View {
    @EnvironmentObject var model: SessionModel

    var body: some View {
        HStack(spacing: 12) {
            if model.isConnected {
                SourceToggle(card: model.card)
                    .padding(.leading, 14)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 6) {
                    ForEach(model.shots) { shot in
                        Thumbnail(image: shot.thumbnail, selected: shot.id == model.selection)
                            .onTapGesture { model.selection = shot.id }
                            .help(shot.name)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
            }

            HStack(spacing: 10) {
                Text("\(model.shots.count) 枚")
                if let buffer = model.bufferRemaining {
                    Label("バッファ \(buffer)", systemImage: "square.stack.3d.up")
                        .help("連写であと何コマ撮れるか")
                }
            }
            .font(.system(size: 11).monospacedDigit())
            .foregroundStyle(Theme.dim)
            .padding(.trailing, 14)
            .fixedSize()
        }
        .frame(height: 84)
        .background(Theme.surface.opacity(0.5))
    }
}

/// コマ 1 枚。表示に使う値だけを受け取る（`Shot` を渡すと ID しか比べられず、サムネイルが届いても描き直されない）
private struct Thumbnail: View {
    let image: NSImage?
    let selected: Bool

    var body: some View {
        ZStack {
            if let image {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
            } else {
                Rectangle().fill(Theme.surfaceRaised)
                ProgressView().controlSize(.mini)
            }
        }
        .frame(width: 96, height: 64)
        .clipShape(RoundedRectangle(cornerRadius: 5))
        .overlay(
            RoundedRectangle(cornerRadius: 5)
                .strokeBorder(selected ? Theme.amber : .clear, lineWidth: 2)
        )
        .contentShape(Rectangle())
    }
}

// MARK: - 撮影設定パネル

struct ShootingInspector: View {
    @EnvironmentObject var model: SessionModel

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    CameraSummary()
                    if model.isConnected {
                        ExposureSection()
                        PictureSection()
                    } else {
                        Text(model.state == .connecting
                             ? LocalizedStringKey("つながると、ここで露出や画質を変えられます。")
                             : LocalizedStringKey("カメラをつなぐと、ここで露出や画質を変えられます。"))
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.dim)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(16)
            }

            ShutterButton(size: 62, busy: model.busy, enabled: model.isConnected) {
                model.shoot()
            }
            .help("シャッター（スペース / ⌘T）")
            .frame(maxWidth: .infinity)
            .padding(.vertical, 18)
        }
        .foregroundStyle(Theme.text)
    }
}

private struct SectionHeader: View {
    let title: LocalizedStringKey

    var body: some View {
        Text(title)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(Theme.dim)
    }
}

/// 機種・焦点距離・電池を 1 行で
private struct CameraSummary: View {
    @EnvironmentObject var model: SessionModel

    private var title: String {
        switch model.state {
        case .connected(let name): return name
        case .connecting:
            switch model.warmup {
            case .system(let name)?, .card(let name)?: return name
            case nil: return String(localized: "接続中…")
            }
        case .waiting: return String(localized: "カメラを待っています")
        case .failed, .disconnected: return String(localized: "未接続")
        }
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title)
                .font(.system(size: 20, weight: .semibold, design: .rounded))
                .foregroundStyle(model.isConnected ? Theme.text : Theme.dim)
            Spacer()
            if let focal = model.currentFocalLength {
                Text(focal)
                    .font(.system(size: 12).monospacedDigit())
                    .foregroundStyle(Theme.dim)
            }
            if let battery = model.batteryPercent {
                BatteryIcon(level: battery)
            }
        }
    }
}

/// カメラの電池。D300 は残量を 20% 刻みの切り上げで返すので、数字ではなく段階のアイコンにする（iOS 版と同じ）
struct BatteryIcon: View {
    let level: Int

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 14))
            .foregroundStyle(level <= 20 ? Theme.danger : Theme.dim)
            .help(Text("カメラの電池 \(Self.rangeText(level))"))
    }

    static func rangeText(_ level: Int) -> String {
        level >= 100 ? String(localized: "満充電") : String(localized: "\(max(0, level - 19))〜\(level)%")
    }

    private var symbol: String {
        switch level {
        case 81...:   return "battery.100percent"
        case 61...80: return "battery.75percent"
        case 41...60: return "battery.50percent"
        case 1...40:  return "battery.25percent"
        default:      return "battery.0percent"
        }
    }
}

/// 撮影モード → 露出計かカメラ任せの値 → モードに合わせたスクラバー
private struct ExposureSection: View {
    @EnvironmentObject var model: SessionModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "露出")

            if let mode = model.props[.exposureProgram], !mode.choices.isEmpty {
                // 選択肢はカメラが申告したものをそのまま出す。機種によって並びも項目数も違う
                Picker("", selection: model.textBinding(for: .exposureProgram)) {
                    ForEach(mode.choiceTexts, id: \.self) { Text($0).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .disabled(!model.isWritable(.exposureProgram))
                .help("露出モード")
            }

            HStack(spacing: 12) {
                if model.lightMeterMeaningful {
                    Text("露出計")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Theme.dim)
                    LightMeterView(value: model.lightMeter)
                } else {
                    ForEach(model.cameraDecided, id: \.self) { prop in
                        if let desc = model.props[prop] {
                            HStack(spacing: 5) {
                                Text(prop.label)
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundStyle(Theme.dim)
                                Text(desc.currentText)
                                    .font(.system(size: 13, weight: .semibold, design: .rounded).monospacedDigit())
                                    .contentTransition(.numericText())
                                    .animation(.snappy(duration: 0.18), value: desc.current)
                            }
                        }
                    }
                }
                Spacer(minLength: 0)
            }
            .frame(height: 20)

            VStack(spacing: 6) {
                ForEach(model.adjustable, id: \.self) { prop in
                    ScrubberControl(title: prop.label,
                                    options: model.props[prop]?.choiceTexts ?? [],
                                    selection: model.textBinding(for: prop),
                                    enabled: model.isWritable(prop))
                }
            }
        }
    }
}

/// 白バランス・画質・フォーカス
private struct PictureSection: View {
    @EnvironmentObject var model: SessionModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(title: "画質とフォーカス")

            if let wb = model.props[.whiteBalance], !wb.choices.isEmpty {
                row("白バランス") {
                    Picker("", selection: model.textBinding(for: .whiteBalance)) {
                        ForEach(wb.choiceTexts, id: \.self) { Text($0).tag($0) }
                    }
                    .labelsHidden()
                    .fixedSize()
                    .disabled(!model.isWritable(.whiteBalance))
                }
            }
            if let quality = model.props[.compressionSetting], !quality.choices.isEmpty {
                row("画質") {
                    Picker("", selection: model.textBinding(for: .compressionSetting)) {
                        ForEach(quality.choiceTexts, id: \.self) { Text($0).tag($0) }
                    }
                    .labelsHidden()
                    .fixedSize()
                    .disabled(!model.isWritable(.compressionSetting))
                }
            }
            if let focus = model.props[.focusMode] {
                row("AF モード") {
                    HStack(spacing: 4) {
                        Text(focus.currentText).font(.system(size: 12, weight: .medium))
                        if !focus.writable {
                            Image(systemName: "lock.fill")
                                .font(.system(size: 8))
                                .foregroundStyle(Theme.dimmer)
                                .help("本体の AF モードスイッチで切り替えます")
                        }
                    }
                }
            }
            row("撮影前に AF") {
                Toggle("", isOn: $model.autofocusBeforeShot)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .labelsHidden()
                    .tint(Theme.amber)
            }
        }
    }

    private func row<Content: View>(_ title: LocalizedStringKey, @ViewBuilder content: () -> Content) -> some View {
        HStack {
            Text(title)
                .font(.system(size: 12))
                .foregroundStyle(Theme.dim)
            Spacer()
            content()
        }
        .frame(minHeight: 26)
    }
}
