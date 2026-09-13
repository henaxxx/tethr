import SwiftUI
import Network

/// 位置情報の状態と設定。操作パネルに置くには項目が多いのでシートに分ける。
struct GeoPanel: View {
    @EnvironmentObject var session: CameraSession
    @Environment(\.dismiss) private var dismiss
    @State private var confirmingClear = false
    @StateObject private var sender = GeoSender()

    private var gpsText: String {
        switch session.gpsMode {
        case .off: return String(localized: "オフ")
        case .precise: return String(localized: "測位中")
        case .holding: return String(localized: "止めています（立ち止まり中）")
        }
    }

    private var hasNothingToSend: Bool {
        session.geoLog.shots.isEmpty && session.geoLog.track.isEmpty
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("撮影地点を記録", isOn: $session.geotagging)
                    Toggle("画面を消しても軌跡を続ける", isOn: $session.trackInBackground)
                        .disabled(!session.geotagging)
                } footer: {
                    Text("カメラのカードには書き込めないため、位置は端末側に控えます。取り込むときに写真へ付き、RAW 本体には手を触れません。")
                }

                Section {
                    Toggle("ポケットに入れたら省電力", isOn: $session.pocketModeEnabled)
                } footer: {
                    Text("カメラをつないだまま iPhone をポケットに入れると画面を消し、露出計の問い合わせとサムネイルの取得を止めます。ポケットの中では自動ロックしないので、撮影通知と位置の記録は続きます。取り出すと、中で撮ったカットを全画面で出します。")
                }

                Section("記録の状況") {
                    LabeledContent("GPS") {
                        Text(gpsText).foregroundStyle(.secondary)
                    }
                    LabeledContent("正確な位置") {
                        Text("\(session.geoLog.shots.count) カット").monospacedDigit()
                    }
                    LabeledContent("軌跡") {
                        Text("\(session.geoLog.track.count) 点").monospacedDigit()
                    }
                    if let period = session.geoLog.trackPeriod {
                        LabeledContent("記録期間", value: period)
                    }
                }

                Section {
                    switch sender.status {
                    case .sending(let name):
                        HStack {
                            ProgressView().controlSize(.small)
                            Text("\(name) へ送信中…").foregroundStyle(.secondary)
                        }
                    case .sent(let name):
                        Label("\(name) へ送りました", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    case .failed(let why):
                        Label(why, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                            .font(.system(size: 12))
                    case .idle, .searching:
                        EmptyView()
                    }

                    if hasNothingToSend {
                        Label("送る記録がまだありません", systemImage: "info.circle")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                    if sender.peers.isEmpty {
                        HStack {
                            ProgressView().controlSize(.small)
                            Text("Mac を探しています…").foregroundStyle(.secondary)
                        }
                    }
                    ForEach(sender.peers) { peer in
                        Button {
                            sender.send(session.geoLog.snapshot(), to: peer)
                        } label: {
                            HStack {
                                Image(systemName: "laptopcomputer")
                                Text(peer.name)
                                Spacer()
                                Image(systemName: "arrow.up.circle.fill").foregroundStyle(Color.accentColor)
                            }
                        }
                        .disabled(hasNothingToSend)
                    }
                } header: {
                    Text("Mac へ送る")
                } footer: {
                    Text("Mac 版 Tethr の「位置情報を付与」ウインドウを開いておくと、ここに現れます。同じ Wi-Fi でなくても、端末同士が直接繋がります。")
                }

                Section {
                    Button("記録を消去", role: .destructive) { confirmingClear = true }
                        .disabled(session.geoLog.shots.isEmpty && session.geoLog.track.isEmpty)
                } footer: {
                    Text("「正確な位置」は接続中に撮ったカットの、ファイル名で確定した位置です。「軌跡」は接続していない間に撮ったカットを、撮影時刻で拾うための記録です。")
                }
            }
            .onAppear { sender.startBrowsing() }
            .onDisappear { sender.stopBrowsing() }
            .navigationTitle("位置情報")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完了") { dismiss() }
                }
            }
            .alert("記録を消去しますか", isPresented: $confirmingClear) {
                Button("消去", role: .destructive) { session.geoLog.clear() }
                Button("やめる", role: .cancel) {}
            } message: {
                Text("控えてある撮影地点と軌跡がすべて失われます。取り込み済みの写真には影響しません。")
            }
        }
        .presentationDetents([.medium, .large])
    }
}
