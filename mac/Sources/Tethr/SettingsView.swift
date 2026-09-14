import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettings()
                .tabItem { Label("一般", systemImage: "gearshape") }
            StorageSettings()
                .tabItem { Label("保存", systemImage: "externaldrive") }
        }
        .frame(width: 470)
    }
}

private struct GeneralSettings: View {
    @EnvironmentObject var model: SessionModel

    var body: some View {
        Form {
            Section {
                Toggle("起動時にカメラへ自動接続する", isOn: $model.autoConnect)
            } footer: {
                Text("カメラとのやり取りは macOS 標準の仕組み（ImageCaptureCore）を通します。ほかのアプリを終了したり、ターミナルで操作したりする必要はありません。")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }

            Section("接続状態") {
                LabeledContent("カメラ", value: model.modelName)
                if let lens = model.lensDescription {
                    LabeledContent("レンズ", value: lens)
                }
                if let serial = model.deviceInfo?.serialNumber, !serial.isEmpty {
                    LabeledContent("シリアル番号", value: serial)
                }
                if let fw = model.deviceInfo?.version, !fw.isEmpty {
                    LabeledContent("ファームウェア", value: fw)
                }
                HStack {
                    Text("カメラ時計")
                    Spacer()
                    Text(model.clockOffsetDescription ?? "―")
                        .foregroundStyle(model.clockOffset.map { abs($0) > 60 } == true ? .orange : .secondary)
                    Button("Mac に合わせる") { model.syncClock() }
                        .disabled(!model.isConnected)
                }
            }

            Section {
                HStack {
                    Text("ログ")
                    Spacer()
                    Button("Finder で表示") {
                        NSWorkspace.shared.activateFileViewerSelecting([Log.url])
                    }
                }
            } footer: {
                Text("接続に失敗したときは \(Log.url.path) に原因が残ります。")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding(.vertical, 8)
    }
}

private struct StorageSettings: View {
    @EnvironmentObject var model: SessionModel

    var body: some View {
        Form {
            Section {
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("テザー保存先").font(.system(size: 12))
                        Text(model.baseDestination.path)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                    }
                    Spacer()
                    Button("変更…") { choose() }
                }

                Toggle("日付ごとのサブフォルダを作る", isOn: $model.useDateSubfolder)
            } footer: {
                VStack(alignment: .leading, spacing: 2) {
                    Text("実際の保存先: \(model.effectiveDestination.path)")
                    Text("撮影ファイルはカメラ側の名前のまま保存され、同名があれば連番を付けます。")
                }
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            }

            Section {
                Toggle("転送後にカメラのカードから削除する", isOn: $model.deleteAfterDownload)
            } footer: {
                Text("既定はオフです。オンにすると転送に成功したファイルをカードから消します。")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding(.vertical, 8)
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = model.baseDestination
        panel.prompt = "ここに保存"
        panel.message = "テザー撮影した画像の保存先を選んでください"
        if panel.runModal() == .OK, let url = panel.url {
            model.baseDestination = url
        }
    }
}
