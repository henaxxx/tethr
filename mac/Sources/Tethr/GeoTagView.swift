import SwiftUI
import UniformTypeIdentifiers

/// 受け取った位置情報を、カードから取り込んだ写真へ付与する画面。
@MainActor
final class GeoTagModel: ObservableObject {
    @Published var payload: GeoPayload?
    @Published var payloadName: String?
    @Published var folder: URL?
    @Published var matches: [GeoWriter.Match] = []
    @Published var unmatched: [URL] = []
    @Published var alreadyTagged: [URL] = []
    @Published var report: GeoWriter.Report?
    @Published var working = false
    @Published var tolerance: Double = 120
    @Published var overwriteExisting = false
    @Published var problem: String?
    @Published private(set) var exifToolVersion: String?
    @Published var scanning = false

    init() {
        // 版数の問い合わせは perl の起動を伴う。
        // 計算プロパティにすると描画のたびに起動してメインスレッドが埋まる。
        // 起動時に一度だけ調べて持っておく。
        let tool = ExifTool.locate()
        DispatchQueue.global(qos: .utility).async {
            let version = tool?.version
            DispatchQueue.main.async { self.exifToolVersion = version }
        }
    }

    /// iPhone から直接受け取った内容を採用する
    func adopt(_ payload: GeoPayload, from sender: String) {
        self.payload = payload
        self.payloadName = String(localized: "\(sender) から受信")
        self.report = nil
        rescan()
    }

    func loadPayload(_ url: URL) {
        do {
            payload = try GeoPayload.decode(try Data(contentsOf: url))
            payloadName = url.lastPathComponent
            report = nil
            rescan()
        } catch {
            problem = String(localized: "位置情報ファイルを読めません: \(error.localizedDescription)")
        }
    }

    func rescan() {
        guard let payload, let folder else {
            matches = []; unmatched = []; alreadyTagged = []
            return
        }
        var writer = GeoWriter(payload: payload)
        writer.tolerance = tolerance
        writer.overwriteExisting = overwriteExisting

        // 走査は 1 枚ごとに EXIF を読む。数百枚あるとメインでは固まる。
        scanning = true
        DispatchQueue.global(qos: .userInitiated).async {
            let result = writer.plan(in: folder)
            DispatchQueue.main.async {
                self.matches = result.matches
                self.unmatched = result.unmatched
                self.alreadyTagged = result.alreadyTagged
                self.scanning = false
            }
        }
    }

    func apply() {
        guard let payload, !matches.isEmpty, !working else { return }
        working = true
        report = nil

        let snapshot = matches
        var writer = GeoWriter(payload: payload)
        writer.tolerance = tolerance
        writer.overwriteExisting = overwriteExisting

        // exiftool の実行は同期的に時間がかかるので別スレッドへ。
        // 完了時の状態解除は、経路を 1 本に絞って取りこぼさないようにする。
        DispatchQueue.global(qos: .userInitiated).async {
            let result = writer.apply(snapshot) { _, _ in }
            DispatchQueue.main.async {
                self.report = result
                self.working = false
                self.rescan()
            }
        }
    }
}

/// iPhone からの受信待ち状況。何もしなくても繋がることを見せる。
struct ReceiverBar: View {
    @ObservedObject var receiver: GeoReceiver

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon).font(.system(size: 12)).foregroundStyle(tint)
            Text(text).font(.system(size: 11))
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 7).fill(tint.opacity(0.10)))
    }

    private var icon: String {
        switch receiver.state {
        case .waiting: return "wifi"
        case .receiving: return "arrow.down.circle"
        case .received: return "checkmark.circle.fill"
        case .failed: return "exclamationmark.triangle.fill"
        case .stopped: return "wifi.slash"
        }
    }

    private var tint: Color {
        switch receiver.state {
        case .received: return .green
        case .failed: return .orange
        case .stopped: return .secondary
        default: return .accentColor
        }
    }

    private var text: String {
        switch receiver.state {
        case .stopped: return String(localized: "待ち受けていません")
        case .waiting(let name): return String(localized: "「\(name)」として待ち受け中。iPhone の Tethr から送信してください")
        case .receiving: return String(localized: "受信中…")
        case .received(let sender, let at):
            let f = DateFormatter(); f.dateFormat = "HH:mm:ss"
            return String(localized: "\(sender) から受信しました（\(f.string(from: at))）")
        case .failed(let why): return String(localized: "受信に失敗: \(why)")
        }
    }
}

struct GeoTagView: View {
    @StateObject private var model = GeoTagModel()
    @StateObject private var receiver = GeoReceiver()

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            ReceiverBar(receiver: receiver)

            HStack(spacing: 10) {
                sourceBox(
                    title: "位置情報",
                    detail: model.payloadName ?? "未選択",
                    subtitle: payloadSummary,
                    action: pickPayload
                )
                sourceBox(
                    title: "写真フォルダ",
                    detail: model.folder?.lastPathComponent ?? "未選択",
                    subtitle: folderSummary,
                    action: pickFolder
                )
            }

            if model.payload != nil && model.folder != nil {
                options
                Divider()
                results
            }

            Spacer(minLength: 0)
            footer
        }
        .padding(16)
        .frame(minWidth: 620, minHeight: 460)
        .onAppear { receiver.start() }
        .onDisappear { receiver.stop() }
        .onChange(of: receiver.lastPayload?.generated) { _, _ in
            // 届いたらそのまま採用する。ファイルを選び直す手間を省く。
            guard case .received(let sender, _) = receiver.state,
                  let payload = receiver.lastPayload else { return }
            model.adopt(payload, from: sender)
        }
        .alert("エラー", isPresented: Binding(
            get: { model.problem != nil },
            set: { if !$0 { model.problem = nil } }
        )) {
            Button("OK") { model.problem = nil }
        } message: { Text(model.problem ?? "") }
    }

    // MARK: 各部

    private var header: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("位置情報を付与").font(.system(size: 15, weight: .semibold))
            Text("iPhone の Tethr で記録した撮影地点を、カードから取り込んだ写真へ書き込みます。")
                .font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }

    private func sourceBox(title: LocalizedStringKey, detail: String, subtitle: String?, action: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
            Text(detail).font(.system(size: 12, weight: .medium)).lineLimit(1).truncationMode(.middle)
            if let subtitle {
                Text(subtitle).font(.system(size: 10)).foregroundStyle(.tertiary).lineLimit(2)
            }
            Button("選択…", action: action).controlSize(.small)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.separator, lineWidth: 1)))
    }

    private var payloadSummary: String? {
        guard let p = model.payload else { return nil }
        var parts = ["正確な位置 \(p.shots.count) 件", "軌跡 \(p.track.count) 点"]
        if let range = p.trackRange {
            let f = DateFormatter()
            f.dateFormat = "M/d HH:mm"
            parts.append("\(f.string(from: range.start))〜\(f.string(from: range.end))")
        }
        return parts.joined(separator: " / ")
    }

    private var folderSummary: String? {
        guard model.folder != nil else { return nil }
        return "対象 \(model.matches.count + model.unmatched.count + model.alreadyTagged.count) 件"
    }

    private var options: some View {
        HStack(spacing: 18) {
            HStack(spacing: 6) {
                Text("時刻の許容差").font(.system(size: 11)).foregroundStyle(.secondary)
                Picker("", selection: $model.tolerance) {
                    Text("30秒").tag(30.0)
                    Text("2分").tag(120.0)
                    Text("10分").tag(600.0)
                    Text("1時間").tag(3600.0)
                }
                .labelsHidden().frame(width: 90).controlSize(.small)
                .onChange(of: model.tolerance) { _, _ in model.rescan() }
            }
            Toggle("既に位置がある写真も上書き", isOn: $model.overwriteExisting)
                .controlSize(.small)
                .onChange(of: model.overwriteExisting) { _, _ in model.rescan() }
            Spacer()
        }
    }

    private var results: some View {
        VStack(alignment: .leading, spacing: 8) {
            let exact = model.matches.filter(\.exact).count
            let byTime = model.matches.count - exact

            HStack(spacing: 14) {
                tally("ファイル名で確定", exact, .green)
                tally("撮影時刻から推定", byTime, .blue)
                if !model.alreadyTagged.isEmpty {
                    tally("既に位置あり", model.alreadyTagged.count, .gray)
                }
                tally("該当なし", model.unmatched.count, .secondary)
            }

            if let report = model.report {
                VStack(alignment: .leading, spacing: 3) {
                    if !report.written.isEmpty {
                        Label("\(report.written.count) 件に書き込みました", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    }
                    if !report.failed.isEmpty {
                        Label("\(report.failed.count) 件は書き込めませんでした: \(report.failed.first?.reason ?? "")",
                              systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    }
                }
                .font(.system(size: 11))
            }

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(model.matches.enumerated()), id: \.offset) { _, m in
                        HStack(spacing: 8) {
                            Circle().fill(m.exact ? Color.green : Color.blue).frame(width: 5, height: 5)
                            Text(m.url.lastPathComponent)
                                .font(.system(size: 11, design: .monospaced))
                            Spacer()
                            if let gap = m.gap {
                                Text("±\(Int(gap))秒").font(.system(size: 10)).foregroundStyle(.tertiary)
                            }
                            Text(String(format: "%.4f, %.4f", m.point.lat, m.point.lon))
                                .font(.system(size: 10).monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(.vertical, 2)
            }
            .frame(minHeight: 120)
        }
    }

    private func tally(_ label: LocalizedStringKey, _ count: Int, _ color: Color) -> some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(label).font(.system(size: 11)) + Text(" \(count)").font(.system(size: 11))
        }
    }

    private var footer: some View {
        HStack {
            if let version = model.exifToolVersion {
                Text("ExifTool \(version)").font(.system(size: 10)).foregroundStyle(.tertiary)
            } else {
                Label("exiftool が見つかりません", systemImage: "exclamationmark.triangle")
                    .font(.system(size: 10)).foregroundStyle(.orange)
            }
            Spacer()
            if model.working || model.scanning { ProgressView().controlSize(.small) }
            Button("書き込む") { model.apply() }
                .keyboardShortcut(.defaultAction)
                .disabled(model.matches.isEmpty || model.working || model.scanning || model.exifToolVersion == nil)
        }
    }

    // MARK: 選択

    private func pickPayload() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.message = "iPhone から受け取った位置情報ファイルを選んでください"
        if panel.runModal() == .OK, let url = panel.url { model.loadPayload(url) }
    }

    private func pickFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.message = "位置情報を付与する写真が入ったフォルダを選んでください"
        if panel.runModal() == .OK, let url = panel.url {
            model.folder = url
            model.rescan()
        }
    }
}
