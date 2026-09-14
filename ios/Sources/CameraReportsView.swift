import SwiftUI
import TethrUI

/// 「接続の記録」。動作を確かめていないカメラをつないだときの記録を並べ、共有シートで送れるようにする
struct CameraReportsView: View {
    @ObservedObject var reporter: CameraReporter
    @Environment(\.dismiss) private var dismiss
    @State private var confirmingDelete = false

    var body: some View {
        NavigationStack {
            List {
                if reporter.reports.isEmpty {
                    ContentUnavailableView("記録はありません", systemImage: "doc.text",
                                           description: Text("動作を確かめていないカメラをつなぐと、ここに残ります。"))
                } else {
                    Section {
                        ForEach(reporter.reports, id: \.self) { url in
                            HStack(spacing: 12) {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(Self.model(of: url)).font(.system(size: 15, weight: .medium))
                                    Text(Self.detail(of: url))
                                        .font(.system(size: 12).monospacedDigit())
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                ShareLink(item: url) {
                                    Image(systemName: "square.and.arrow.up")
                                        .font(.system(size: 16, weight: .medium))
                                        .frame(width: 44, height: 44)
                                }
                                .accessibilityLabel(Text("共有"))
                            }
                        }
                        .onDelete { offsets in
                            for index in offsets { reporter.delete(reporter.reports[index]) }
                        }
                    } footer: {
                        Text("動作を確かめていないカメラをつないだときの記録です。カメラの機種、カメラが対応を名乗った命令、送った命令の結果、一覧や取り込みの成否が入ります。シリアル番号と位置情報は入りません。共有しない限り、この端末の外には出ません。")
                    }
                }
            }
            .navigationTitle("接続の記録")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完了") { dismiss() }
                }
                if !reporter.reports.isEmpty {
                    ToolbarItem(placement: .destructiveAction) {
                        Button("すべて削除", role: .destructive) { confirmingDelete = true }
                    }
                }
            }
            .alert("記録をすべて削除しますか", isPresented: $confirmingDelete) {
                Button("削除", role: .destructive) { reporter.deleteAll() }
                Button("やめる", role: .cancel) {}
            }
        }
        .tint(Theme.amber)
    }

    /// ファイル名は「20260915-013045 機種.txt」
    private static func model(of url: URL) -> String {
        let name = url.deletingPathExtension().lastPathComponent
        guard let space = name.firstIndex(of: " ") else { return name }
        return name[name.index(after: space)...].replacingOccurrences(of: "_", with: " ")
    }

    private static func detail(of url: URL) -> String {
        let name = url.deletingPathExtension().lastPathComponent
        let stamp = String(name.prefix(15))
        let parser = DateFormatter()
        parser.dateFormat = "yyyyMMdd-HHmmss"
        parser.locale = Locale(identifier: "en_US_POSIX")
        let date = parser.date(from: stamp).map { $0.formatted(date: .abbreviated, time: .shortened) } ?? stamp
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map { ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file) } ?? ""
        return "\(date)  \(size)"
    }
}
