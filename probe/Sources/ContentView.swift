import SwiftUI
import ImageCaptureCore

struct ContentView: View {
    @EnvironmentObject var probe: CameraProbe

    var body: some View {
        NavigationStack {
            List {
                Section("検証（2026-09-13）") {
                    Button("制御権とライブビューを検証") {
                        Task { await probe.verifyControlAndLiveView() }
                    }
                    .font(.headline)
                    .disabled(probe.openedName == nil)
                    Button(probe.measuring ? "計測中…（約5分、そのまま置いておく）" : "接続速度を計測") {
                        Task { await probe.measureConnections() }
                    }
                    .font(.headline)
                    .disabled(probe.devices.isEmpty || probe.measuring)
                    if let img = probe.liveImage {
                        Image(uiImage: img).resizable().aspectRatio(contentMode: .fit).frame(maxHeight: 200)
                    }
                }

                Section("手順") {
                    Button(probe.browsing ? "検出を停止" : "検出を開始") {
                        probe.browsing ? probe.stop() : probe.start()
                    }
                    Button("PTP 疎通確認 (GetDeviceInfo)") { probe.testPTP() }
                        .disabled(probe.openedName == nil)
                }

                Section("撮影") {
                    Button("リモートシャッター (0x100E)") { probe.remoteShutter() }
                    Button("Nikon 撮影 (0x90C0)") { probe.nikonCapture() }
                }
                .disabled(probe.openedName == nil)

                Section("設定の読み出し") {
                    Button("絞り") { probe.readAperture() }
                    Button("ISO") { probe.readISO() }
                    Button("バッテリー") { probe.readBattery() }
                }
                .disabled(probe.openedName == nil)

                Section("設定の書き込み") {
                    Button("ISO を 400 に変更 (0x1016)") { probe.writeISO400() }
                }
                .disabled(probe.openedName == nil)

                Section("制御権") {
                    Button("制御権を取得 (0x90C2 → 1)") { probe.takeControl() }
                    Button("制御権を返す (0x90C2 → 0)") { probe.releaseControl() }
                }
                .disabled(probe.openedName == nil)

                Section("背面レビュー") {
                    Button("撮影直後の画像確認 (0xD165)") { probe.readImageReview() }
                    Button("記録先 (0xD10B)") { probe.readRecordingMedia() }
                    Button("記録先をカードに戻す") { probe.setRecordingMediaCard() }
                }
                .disabled(probe.openedName == nil)

                Section("ライブビュー") {
                    Button("libgphoto2 と同じ手順で開始して1コマ取得") { probe.liveViewSequence() }
                    Button("開始 (0x9201)") { probe.liveViewStart() }
                    Button("画像を取得 (0x9203)") { probe.liveViewGrab() }
                    Button("終了 (0x9202)") { probe.liveViewStop() }
                    if let img = probe.liveImage {
                        Image(uiImage: img)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(maxHeight: 220)
                    }
                }
                .disabled(probe.openedName == nil)

                Section("検出されたデバイス") {
                    if probe.devices.isEmpty {
                        Text("なし").foregroundStyle(.secondary)
                    }
                    ForEach(Array(probe.devices.enumerated()), id: \.offset) { _, device in
                        Button {
                            probe.open(device)
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(device.name ?? "名前なし").font(.body)
                                Text("種別 \(device.type.rawValue)  \(String(describing: type(of: device)))")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }

                if !probe.files.isEmpty {
                    Section("カード内のファイル（\(probe.files.count) 件）") {
                        ForEach(probe.files.prefix(15), id: \.self) { Text($0).font(.caption.monospaced()) }
                        if probe.files.count > 15 {
                            Text("ほか \(probe.files.count - 15) 件").foregroundStyle(.secondary)
                        }
                    }
                }

                Section("経過") {
                    ForEach(probe.findings) { f in
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: icon(f.ok))
                                .foregroundStyle(color(f.ok))
                                .font(.caption)
                            Text(f.text).font(.caption)
                        }
                    }
                }
            }
            .navigationTitle("TethrProbe")
        }
    }

    private func icon(_ ok: Bool?) -> String {
        guard let ok else { return "circle" }
        return ok ? "checkmark.circle.fill" : "xmark.circle.fill"
    }

    private func color(_ ok: Bool?) -> Color {
        guard let ok else { return .secondary }
        return ok ? .green : .red
    }
}
