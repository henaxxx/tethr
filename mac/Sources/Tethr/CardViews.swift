import SwiftUI
import TethrKit
import TethrUI

/// テザー撮影ぶんとカード内を切り替える（iOS 版と同じ標準のセグメント）
struct SourceToggle: View {
    @EnvironmentObject var model: SessionModel
    @ObservedObject var card: CardModel

    var body: some View {
        Picker("", selection: $card.active) {
            Text("テザー \(model.shots.count)").tag(false)
            Text(cardLabel).tag(true)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
        .disabled(!model.isConnected)
    }

    private var cardLabel: String {
        card.loading && card.items.isEmpty
            ? String(localized: "カード 読込中")
            : String(localized: "カード \(card.items.count)")
    }
}

// MARK: - 一覧

/// カードの中身を格子で並べる。1 枚を大きく見ているときはその絵を出す
struct CardBrowser: View {
    @EnvironmentObject var model: SessionModel
    @ObservedObject var card: CardModel

    var body: some View {
        ZStack {
            Theme.background
            if model.preparing {
                WarmupOverlay()
            } else if card.focus != nil {
                CardPreview(card: card)
            } else if card.loading {
                CardLoadingView(count: card.items.count, expected: card.expected)
            } else if card.items.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "sdcard")
                        .font(.system(size: 36, weight: .ultraLight))
                        .foregroundStyle(Theme.dimmer)
                    Text("カードに写真がありません")
                }
                .font(.system(size: 13))
                .foregroundStyle(Theme.dim)
            } else {
                grid
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var grid: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150, maximum: 230), spacing: 10)], spacing: 14) {
                ForEach(card.items) { item in
                    CardCell(name: item.name, image: item.thumbnail, imported: item.imported,
                             locatable: item.locatable, selected: card.selection.contains(item.id))
                        .onTapGesture { card.click(item.id) }
                        .simultaneousGesture(TapGesture(count: 2).onEnded { card.open(item.id) })
                        .onAppear { card.requestThumbnail(for: item.id) }
                        .onDisappear { card.cancelThumbnail(for: item.id) }
                        .help(item.captured.map { $0.formatted(date: .abbreviated, time: .standard) } ?? item.name)
                }
            }
            .padding(16)
        }
    }
}

/// 格子の 1 マス。表示に使う値だけを受け取る
private struct CardCell: View {
    let name: String
    let image: NSImage?
    let imported: Bool
    let locatable: Bool
    let selected: Bool

    var body: some View {
        VStack(spacing: 5) {
            ZStack {
                Theme.surface
                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                } else {
                    ProgressView().controlSize(.small)
                }
            }
            .aspectRatio(3 / 2, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(alignment: .topTrailing) {
                if locatable {
                    Image(systemName: "location.fill")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.7), radius: 2)
                        .padding(5)
                        .help("iPhone の記録から位置を付けられます")
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if imported {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(Theme.onAmber, Theme.amber)
                        .padding(4)
                        .help("取り込み済み")
                }
            }
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(selected ? Theme.amber : .clear, lineWidth: 2.5)
            )

            Text(name)
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(selected ? Theme.text : Theme.dim)
                .lineLimit(1)
        }
        .contentShape(Rectangle())
    }
}

/// 1 枚を大きく見る。← → で送り、Esc かダブルクリックで一覧へ戻る
private struct CardPreview: View {
    @ObservedObject var card: CardModel
    @FocusState private var focused: Bool

    private var index: Int? { card.items.firstIndex { $0.id == card.focus } }

    var body: some View {
        ZStack {
            if let image = card.preview {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .padding(12)
            } else {
                ProgressView()
            }

            HStack {
                arrow("chevron.left", visible: (index ?? 0) > 0) { card.step(-1) }
                Spacer()
                arrow("chevron.right", visible: (index ?? 0) < card.items.count - 1) { card.step(1) }
            }
            .padding(.horizontal, 16)

            VStack {
                HStack {
                    Spacer()
                    Button { card.close() } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 13, weight: .semibold))
                            .frame(width: 32, height: 32)
                            .glassCircle()
                    }
                    .buttonStyle(.plain)
                    .help("一覧へ戻る（Esc）")
                }
                Spacer()
            }
            .padding(14)
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { card.close() }
        .focusable()
        .focused($focused)
        .focusEffectDisabled()
        .onAppear { focused = true }
        .onKeyPress(.leftArrow) { card.step(-1); return .handled }
        .onKeyPress(.rightArrow) { card.step(1); return .handled }
        .onKeyPress(.escape) { card.close(); return .handled }
    }

    /// 行き先が無い側は出さない（場所は保つ）
    private func arrow(_ symbol: String, visible: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 18, weight: .semibold))
                .frame(width: 40, height: 40)
                .glassCircle()
        }
        .buttonStyle(.plain)
        .opacity(visible ? 1 : 0)
        .allowsHitTesting(visible)
    }
}

// MARK: - 一覧の下の段

/// 選んでいるカット（大きく見ているカット）の情報
struct CardInfoRow: View {
    @ObservedObject var card: CardModel

    private var item: CardItem? {
        let id = card.focus ?? (card.selection.count == 1 ? card.selection.first : nil)
        return id.flatMap { id in card.items.first { $0.id == id } }
    }

    var body: some View {
        HStack(spacing: 10) {
            if let item {
                Text(item.name).font(.system(size: 12, weight: .medium))
                if let captured = item.captured {
                    Text(captured.formatted(date: .abbreviated, time: .standard))
                        .font(.system(size: 12).monospacedDigit())
                        .foregroundStyle(Theme.dim)
                }
                Text(ByteCountFormatter.string(fromByteCount: item.size, countStyle: .file))
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(Theme.dimmer)
                if item.imported {
                    Label("取り込み済み", systemImage: "checkmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.amber)
                }
                if item.locatable {
                    Label("位置を付けられます", systemImage: "location.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.dim)
                }
            } else if card.selection.count > 1 {
                Text("\(card.selection.count) 枚を選択中")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.dim)
            } else {
                Text("クリックで選択、⌘・⇧ で複数選択、ダブルクリックで大きく表示")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.dimmer)
            }
            Spacer()
        }
        .lineLimit(1)
        .padding(.horizontal, 14)
        .frame(height: 40)
    }
}

/// 取り込みの操作。枚数、位置情報の状況、取り込みの進み具合と、2 つの取り込みボタン
struct CardActionBar: View {
    @ObservedObject var card: CardModel
    @ObservedObject var geo: GeoStore

    private var selectedRemaining: Int {
        card.items.filter { card.selection.contains($0.id) && !$0.imported }.count
    }

    var body: some View {
        HStack(spacing: 14) {
            SourceToggle(card: card)

            VStack(alignment: .leading, spacing: 5) {
                statusLine
                geoLine
            }
            .font(.system(size: 11))
            .lineLimit(1)

            Spacer(minLength: 8)

            Button("選んだ \(selectedRemaining) 枚を取り込む") { card.importSelected() }
                .disabled(selectedRemaining == 0 || card.importing)
            Button("未取り込みをすべて取り込む（\(card.unimported.count)）") { card.importAllRemaining() }
                .buttonStyle(.borderedProminent)
                .tint(Theme.amber)
                .disabled(card.unimported.isEmpty || card.importing || card.loading)
                .help(card.loading ? String(localized: "カードの一覧が出そろってから使えます") : "")
        }
        .padding(.horizontal, 14)
        .frame(height: 84)
        .background(Theme.surface.opacity(0.5))
    }

    @ViewBuilder
    private var statusLine: some View {
        switch card.importPhase {
        case .downloading(let done, let total)?:
            HStack(spacing: 8) {
                ProgressView(value: Double(done), total: Double(max(total, 1)))
                    .frame(width: 120)
                    .tint(Theme.amber)
                Text("取り込み中 \(done) / \(total)").monospacedDigit()
            }
        case .geotagging(let count)?:
            HStack(spacing: 8) {
                ProgressView().controlSize(.mini)
                Text("位置を書き込み中（\(count) 枚）")
            }
        case nil:
            if let summary = card.lastSummary {
                Label(summary, systemImage: "checkmark.circle.fill")
                    .foregroundStyle(Theme.amber)
            } else {
                Text(card.loading
                     ? loadingText
                     : String(localized: "\(card.items.count) 枚・未取り込み \(card.unimported.count) 枚"))
                    .foregroundStyle(Theme.text)
                    .monospacedDigit()
            }
        }
    }

    private var loadingText: String {
        if let expected = card.expected {
            return String(localized: "カードを読み込み中 \(card.items.count) / \(expected) 件")
        }
        return String(localized: "カードを読み込み中 \(card.items.count) 件")
    }

    @ViewBuilder
    private var geoLine: some View {
        if let payload = geo.payload {
            HStack(spacing: 8) {
                Image(systemName: "location.fill").foregroundStyle(Theme.amber)
                Text(geoSummary(payload))
                    .foregroundStyle(Theme.dim)
                    .help(String(localized: "\(geo.sender ?? "iPhone") から \(geo.receivedAt?.formatted(date: .abbreviated, time: .shortened) ?? "") に受け取った記録（正確な位置 \(payload.shots.count) 件・軌跡 \(payload.track.count) 点）"))
                Toggle("取り込み時に書き込む", isOn: $card.writeLocations)
                    .toggleStyle(.checkbox)
                    .controlSize(.small)
            }
        } else {
            HStack(spacing: 6) {
                Image(systemName: "location.slash").foregroundStyle(Theme.dimmer)
                Text("位置情報なし。iPhone の Tethr から Mac へ送ると、取り込むときに書き込めます")
                    .foregroundStyle(Theme.dimmer)
            }
        }
    }

    /// 下の段は横幅が限られるので枚数だけ。いつ誰から受け取ったかは、マウスを乗せたときに出す
    private func geoSummary(_ payload: GeoPayload) -> String {
        String(localized: "位置あり \(card.locatableCount) 枚")
    }
}
