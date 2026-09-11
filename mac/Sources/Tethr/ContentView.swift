import SwiftUI

struct ContentView: View {
    @EnvironmentObject var model: SessionModel
    @State private var showInspector = true

    var body: some View {
        VStack(spacing: 0) {
            StatusBar()
            if model.destinationProblem != nil || !model.failedTransfers.isEmpty {
                Divider()
                DestinationWarning()
            }
            Divider()
            PreviewPane()
            Divider()
            Filmstrip()
                .frame(height: 132)
        }
        .inspector(isPresented: $showInspector) {
            ShootingInspector()
                .inspectorColumnWidth(min: 268, ideal: 300, max: 380)
        }
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                Button {
                    model.isConnected ? model.disconnect() : model.connect()
                } label: {
                    Label(model.isConnected ? "切断" : "接続",
                          systemImage: model.isConnected ? "cable.connector.slash" : "cable.connector")
                        .labelStyle(.titleAndIcon)
                }
                .disabled(model.state == .connecting)

                Button {
                    model.toggleLiveView()
                } label: {
                    Label("ライブビュー", systemImage: model.isLive ? "eye.fill" : "eye")
                        .labelStyle(.titleAndIcon)
                }
                .disabled(!model.isConnected)
                .help("ミラーアップして映像を受け取ります")

                Button {
                    model.autofocus()
                } label: {
                    Label("AF", systemImage: "viewfinder.circle")
                        .labelStyle(.titleAndIcon)
                }
                .disabled(!model.isConnected || model.afState == .running)
                .keyboardShortcut("f", modifiers: .command)
                .help("AF を実行（シャッター半押し相当）")

                Button {
                    model.shoot()
                } label: {
                    Label("シャッター", systemImage: "camera.shutter.button")
                        .labelStyle(.titleAndIcon)
                }
                .disabled(!model.isConnected || model.busy)
                .keyboardShortcut(.space, modifiers: [])
            }

            ToolbarItemGroup(placement: .primaryAction) {
                Button { showInspector.toggle() } label: {
                    Label("撮影設定", systemImage: "sidebar.trailing")
                }
                .help("撮影設定パネル")
            }
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

/// 保存先が書けない、または転送に失敗したコマがあることを知らせる帯。
/// 撮影中に見落とすと取り返しがつかないので、常時見える位置に出す。
struct DestinationWarning: View {
    @EnvironmentObject var model: SessionModel

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                if let problem = model.destinationProblem {
                    Text(problem).font(.system(size: 12, weight: .medium))
                }
                if !model.failedTransfers.isEmpty {
                    Text("転送できなかったコマ: \(model.failedTransfers.joined(separator: ", "))  — カメラのカードには残っています")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            Spacer()
            Button("再確認") { model.clearFailedTransfers() }
                .controlSize(.small)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .background(Color.orange.opacity(0.12))
    }
}

// MARK: - 上部ステータス

struct StatusBar: View {
    @EnvironmentObject var model: SessionModel

    var body: some View {
        HStack(spacing: 16) {
            HStack(spacing: 6) {
                Circle().fill(statusColor).frame(width: 8, height: 8)
                Text(statusText).font(.system(size: 12, weight: .medium))
            }

            switch model.afState {
            case .running:
                HStack(spacing: 5) {
                    ProgressView().controlSize(.small).scaleEffect(0.6).frame(width: 12, height: 12)
                    Text("AF 実行中").font(.system(size: 12))
                }
            case .succeeded:
                Label("AF 完了", systemImage: "checkmark.circle.fill")
                    .font(.system(size: 12)).foregroundStyle(.green)
            case .failed:
                Label("AF 失敗", systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 12)).foregroundStyle(.orange)
                    .help(model.afFailureDetail ?? "")
            case .idle:
                EmptyView()
            }

            if let buf = model.bufferRemaining {
                Label("バッファ \(buf)", systemImage: "square.stack.3d.up")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }

            Spacer()
            if model.isConnected { LightMeterView(value: model.lightMeter) }
            Spacer()

            Button {
                NSWorkspace.shared.open(model.effectiveDestination)
            } label: {
                Label(model.effectiveDestination.lastPathComponent, systemImage: "folder")
                    .font(.system(size: 12))
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .help(model.effectiveDestination.path)

            Text("\(model.shots.count) 枚")
                .font(.system(size: 12).monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private var statusColor: Color {
        switch model.state {
        case .connected: return .green
        case .connecting: return .orange
        case .failed: return .red
        case .disconnected: return .secondary
        }
    }

    private var statusText: String {
        switch model.state {
        case .connected(let m): return m
        case .connecting: return String(localized: "接続中…")
        case .failed(let e): return e
        case .disconnected: return String(localized: "未接続")
        }
    }
}

struct LightMeterView: View {
    let value: Double?

    var body: some View {
        let ev = max(-3, min(3, value ?? 0))
        HStack(spacing: 8) {
            Text("−3").font(.system(size: 9)).foregroundStyle(.tertiary)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    HStack(spacing: 0) {
                        ForEach(0..<13) { i in
                            Rectangle()
                                .fill(i % 2 == 0 ? Color.secondary.opacity(0.45) : Color.secondary.opacity(0.2))
                                .frame(width: 1, height: i == 6 ? 12 : (i % 2 == 0 ? 8 : 5))
                            if i < 12 { Spacer(minLength: 0) }
                        }
                    }
                    .frame(height: 12)

                    if value != nil {
                        Capsule()
                            .fill(abs(ev) < 0.2 ? Color.green : Color.orange)
                            .frame(width: 3, height: 14)
                            .offset(x: (geo.size.width - 3) * ((ev + 3) / 6))
                            .animation(.easeOut(duration: 0.12), value: ev)
                    }
                }
                .frame(height: 14)
            }
            .frame(width: 180, height: 14)
            Text("+3").font(.system(size: 9)).foregroundStyle(.tertiary)
            Text(value.map { String(format: "%+.1f", $0) } ?? "—")
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 34, alignment: .leading)
        }
    }
}

// MARK: - プレビュー（拡大・パン対応）

struct PreviewPane: View {
    @EnvironmentObject var model: SessionModel

    @State private var zoom: CGFloat = 1          // 1 = ウィンドウにフィット
    @State private var offset: CGSize = .zero
    @State private var offsetAtDragStart: CGSize = .zero
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
                Color(nsColor: .textBackgroundColor).opacity(0.35)

                if model.isLive {
                    if let frame = model.liveFrame {
                        Image(nsImage: frame)
                            .resizable()
                            .interpolation(.medium)
                            .aspectRatio(contentMode: .fit)
                            .padding(12)
                    } else {
                        VStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("ライブビュー開始中…")
                                .font(.system(size: 12)).foregroundStyle(.secondary)
                        }
                    }

                    VStack {
                        HStack {
                            HStack(spacing: 5) {
                                Circle().fill(.red).frame(width: 7, height: 7)
                                Text("LIVE").font(.system(size: 10, weight: .bold, design: .rounded))
                                if model.liveFPS > 0 {
                                    Text("\(model.liveFPS) fps")
                                        .font(.system(size: 10).monospacedDigit())
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .padding(.horizontal, 8).padding(.vertical, 4)
                            .background(.regularMaterial, in: Capsule())
                            Spacer()
                        }
                        Spacer()
                    }
                    .padding(12)
                } else if let shot = selected {
                    if let img = image {
                        let fit = fitScale(image: img, in: geo.size)
                        let effective = zoom * pinch

                        Image(nsImage: img)
                            .resizable()
                            .interpolation(.high)
                            .aspectRatio(contentMode: .fit)
                            .scaleEffect(effective)
                            .offset(clamped(offset, image: img, fit: fit, zoom: effective, view: geo.size))
                            .frame(width: geo.size.width, height: geo.size.height)
                            .clipped()
                            .contentShape(Rectangle())
                            .gesture(panGesture(image: img, fit: fit, view: geo.size))
                            .gesture(magnifyGesture)
                            .onTapGesture(coordinateSpace: .local) { location in
                                zoomToggle(at: location, image: img, fit: fit, view: geo.size)
                            }

                        VStack {
                            Spacer()
                            HStack(alignment: .bottom) {
                                InfoStrip(shot: shot)
                                Spacer()
                                ZoomControls(
                                    percent: Int((fit * effective * 100).rounded()),
                                    canZoomOut: zoom > 1.02,
                                    zoomIn: { setZoom(zoom * 1.5) },
                                    zoomOut: { setZoom(zoom / 1.5) },
                                    fit: { setZoom(1) },
                                    actual: { setZoom(1 / fit) }
                                )
                            }
                            .padding(12)
                        }
                    } else {
                        ProgressView().controlSize(.small)
                    }
                } else {
                    VStack(spacing: 10) {
                        Image(systemName: "camera.macro")
                            .font(.system(size: 40, weight: .ultraLight))
                            .foregroundStyle(.tertiary)
                        Text(model.isConnected
                             ? "カメラのシャッターを押すと、ここに表示されます"
                             : "「接続」を押してください")
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onChange(of: model.selection) { _, newValue in
            zoom = 1
            offset = .zero
            model.loadFullPreview(for: newValue)
        }
    }

    // MARK: 拡大まわり

    private func fitScale(image: NSImage, in view: CGSize) -> CGFloat {
        let w = image.size.width, h = image.size.height
        guard w > 0, h > 0 else { return 1 }
        return min(view.width / w, view.height / h)
    }

    private func setZoom(_ new: CGFloat) {
        let z = min(max(new, 1), 12)
        withAnimation(.easeOut(duration: 0.15)) {
            zoom = z
            if z <= 1.02 { offset = .zero }
        }
        if z <= 1.02 { offsetAtDragStart = .zero }
    }

    /// クリック 1 回でフィットと等倍を往復する（Lightroom と同じ操作感）。
    /// 拡大するときは、クリックした場所が画面中央に来るように寄せる。
    /// 単に倍率だけ上げると画面中心が拡大されてしまい、
    /// 見たかった場所がフレームの外へ出ていく。
    private func zoomToggle(at point: CGPoint, image: NSImage, fit: CGFloat, view: CGSize) {
        if zoom > 1.02 {
            withAnimation(.easeOut(duration: 0.18)) {
                zoom = 1
                offset = .zero
            }
            offsetAtDragStart = .zero
            return
        }

        let target = 1 / max(fit, 0.0001)          // 等倍
        let fitW = image.size.width * fit
        let fitH = image.size.height * fit
        guard fitW > 0, fitH > 0 else { return }

        // クリック位置が画像のどこか（中心を 0 とした割合）
        let centerX = view.width / 2 + offset.width
        let centerY = view.height / 2 + offset.height
        let nx = (point.x - centerX) / (fitW * zoom)
        let ny = (point.y - centerY) / (fitH * zoom)

        // その点が画面中央に来る位置へ動かす
        let wanted = CGSize(width: -nx * fitW * target, height: -ny * fitH * target)
        let settled = clamped(wanted, image: image, fit: fit, zoom: target, view: view)

        withAnimation(.easeOut(duration: 0.18)) {
            zoom = target
            offset = settled
        }
        offsetAtDragStart = settled
    }

    private var magnifyGesture: some Gesture {
        MagnifyGesture()
            .updating($pinch) { value, state, _ in state = value.magnification }
            .onEnded { value in setZoom(zoom * value.magnification) }
    }

    private func panGesture(image: NSImage, fit: CGFloat, view: CGSize) -> some Gesture {
        DragGesture()
            .onChanged { value in
                guard zoom > 1.02 else { return }
                offset = CGSize(width: offsetAtDragStart.width + value.translation.width,
                                height: offsetAtDragStart.height + value.translation.height)
            }
            .onEnded { _ in
                offset = clamped(offset, image: image, fit: fit, zoom: zoom, view: view)
                offsetAtDragStart = offset
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

private struct InfoStrip: View {
    @EnvironmentObject var model: SessionModel
    let shot: Shot

    var body: some View {
        HStack(spacing: 10) {
            Text(shot.name).font(.system(size: 11, weight: .medium))
            if !shot.meta.summary.isEmpty {
                Text(shot.meta.summary).font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            if shot.meta.pixelWidth > 0 {
                Text("\(shot.meta.pixelWidth)×\(shot.meta.pixelHeight)")
                    .font(.system(size: 11)).foregroundStyle(.tertiary)
            }
            Button {
                model.revealInFinder(shot)
            } label: {
                Image(systemName: "folder").font(.system(size: 10))
            }
            .buttonStyle(.borderless)
            .help("Finder で表示")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.regularMaterial, in: Capsule())
    }
}

private struct ZoomControls: View {
    let percent: Int
    let canZoomOut: Bool
    let zoomIn: () -> Void
    let zoomOut: () -> Void
    let fit: () -> Void
    let actual: () -> Void

    var body: some View {
        HStack(spacing: 2) {
            Button(action: zoomOut) { Image(systemName: "minus.magnifyingglass") }
                .disabled(!canZoomOut)
            Text("\(percent)%")
                .font(.system(size: 11).monospacedDigit())
                .frame(width: 46)
            Button(action: zoomIn) { Image(systemName: "plus.magnifyingglass") }
            Divider().frame(height: 14)
            Button(action: fit) { Image(systemName: "arrow.up.left.and.arrow.down.right") }
                .help("フィット")
            Button(action: actual) { Image(systemName: "1.square") }
                .help("等倍表示")
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(.regularMaterial, in: Capsule())
    }
}

// MARK: - フィルムストリップ

struct Filmstrip: View {
    @EnvironmentObject var model: SessionModel

    var body: some View {
        ScrollView(.horizontal, showsIndicators: true) {
            LazyHStack(spacing: 8) {
                ForEach(model.shots) { shot in
                    ZStack {
                        if let img = shot.thumbnail {
                            Image(nsImage: img).resizable().aspectRatio(contentMode: .fill)
                        } else {
                            Rectangle().fill(.quaternary)
                            ProgressView().controlSize(.small)
                        }
                    }
                    .frame(width: 150, height: 100)
                    .clipped()
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                    .overlay(
                        RoundedRectangle(cornerRadius: 4)
                            .strokeBorder(shot.id == model.selection ? Color.accentColor : Color.clear,
                                          lineWidth: 2)
                    )
                    .onTapGesture { model.selection = shot.id }
                    .help(shot.name)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 14)
        }
    }
}

// MARK: - 撮影設定インスペクタ

struct ShootingInspector: View {
    @EnvironmentObject var model: SessionModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                CameraBadge()

                VStack(alignment: .leading, spacing: 8) {
                    Text("撮影設定")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)

                    if let modes = model.choices["expprogram"], !modes.isEmpty {
                        Picker("", selection: model.binding(for: "expprogram")) {
                            ForEach(modes, id: \.self) { Text($0).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .disabled(!model.isWritable("expprogram"))
                        .help("露出モード")
                    } else if let mode = model.settings["expprogram"] {
                        Text(mode)
                            .font(.system(size: 10, weight: .bold, design: .rounded))
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(.quaternary, in: RoundedRectangle(cornerRadius: 4))
                    }

                    VStack(spacing: 10) {
                        ScrubberControl(title: "シャッター",
                                        options: model.choices["shutterspeed"] ?? [],
                                        format: Format.shutter,
                                        selection: model.binding(for: "shutterspeed"),
                                        enabled: model.isWritable("shutterspeed"),
                                        locked: model.readonlyKeys.contains("shutterspeed"))
                        ScrubberControl(title: "絞り",
                                        options: model.choices["f-number"] ?? [],
                                        format: Format.aperture,
                                        selection: model.binding(for: "f-number"),
                                        enabled: model.isWritable("f-number"),
                                        locked: model.readonlyKeys.contains("f-number"))
                        ScrubberControl(title: "ISO",
                                        options: model.choices["iso"] ?? [],
                                        format: Format.iso,
                                        selection: model.binding(for: "iso"),
                                        enabled: model.isWritable("iso"),
                                        locked: model.readonlyKeys.contains("iso"))
                    }
                    .padding(.top, 2)

                    if let ec = model.settings["exposurecompensation"] {
                        HStack {
                            Text("露出補正").font(.system(size: 11)).foregroundStyle(.secondary)
                            Spacer()
                            Text(Format.exposureCompensation(ec))
                                .font(.system(size: 11, weight: .medium).monospacedDigit())
                        }
                        .padding(.top, 2)
                    }
                }
                .padding(12)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color(nsColor: .controlBackgroundColor))
                        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.separator, lineWidth: 1))
                )

                VStack(alignment: .leading, spacing: 8) {
                    Text("フォーカス")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)

                    if let mode = model.settings["focusmode"] {
                        HStack {
                            Text("モード").font(.system(size: 11)).foregroundStyle(.secondary)
                            Spacer()
                            Text(mode).font(.system(size: 11, weight: .medium))
                            Image(systemName: "lock.fill")
                                .font(.system(size: 8)).foregroundStyle(.tertiary)
                                .help("本体の AF モードスイッチで切り替えます")
                        }
                    }

                    Toggle("シャッター時に AF する", isOn: model.autofocusOnCapture)
                        .font(.system(size: 11))
                        .controlSize(.small)
                        .disabled(!model.isWritable("autofocus"))

                    Button {
                        model.autofocus()
                    } label: {
                        Label("AF を実行", systemImage: "viewfinder.circle")
                            .frame(maxWidth: .infinity)
                    }
                    .controlSize(.small)
                    .disabled(!model.isConnected || model.afState == .running)
                }
                .padding(12)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color(nsColor: .controlBackgroundColor))
                        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.separator, lineWidth: 1))
                )

                VStack(alignment: .leading, spacing: 8) {
                    ForEach(SessionModel.menuKeys, id: \.self) { key in
                        if let options = model.choices[key], !options.isEmpty {
                            Picker(Self.labels[key] ?? key, selection: model.binding(for: key)) {
                                ForEach(options, id: \.self) { Text($0).tag($0) }
                            }
                            .controlSize(.small)
                            .disabled(!model.isWritable(key))
                        }
                    }
                }

                Spacer(minLength: 0)
            }
            .padding(12)
        }
    }

    static var labels: [String: String] {
        ["whitebalance": String(localized: "WB"),
         "imagequality": String(localized: "画質")]
    }
}
