import SwiftUI

@main
struct TethrApp: App {
    @StateObject private var model = SessionModel()
    @Environment(\.openWindow) private var openWindow

    private func openGeoTag() { openWindow(id: "geotag") }

    var body: some Scene {
        WindowGroup("Tethr") {
            ContentView()
                .environmentObject(model)
                .frame(minWidth: 940, minHeight: 640)
                .onAppear { if model.autoConnect { model.connect() } }
        }
        .defaultSize(width: 1240, height: 820)
        .commands {
            CommandGroup(replacing: .newItem) { }
            CommandMenu("カメラ") {
                Button("接続") { model.connect() }
                    .disabled(model.isConnected)
                Button("切断") { model.disconnect() }
                    .disabled(!model.isConnected)
                Divider()
                Button(model.isLive ? "ライブビューを止める" : "ライブビューを開始") {
                    model.toggleLiveView()
                }
                .keyboardShortcut("l", modifiers: .command)
                .disabled(!model.isConnected)
                Button("AF を実行") { model.autofocus() }
                    .keyboardShortcut("f", modifiers: .command)
                    .disabled(!model.isConnected)
                Button("シャッター") { model.shoot() }
                    .keyboardShortcut("t", modifiers: .command)
                    .disabled(!model.isConnected)
                Button("設定を再読み込み") { model.refreshSettings() }
                    .keyboardShortcut("r", modifiers: .command)
                    .disabled(!model.isConnected)
                Button("本体の操作を戻す") { model.releaseCameraControl() }
                    .disabled(!model.isConnected)
                    .help("上面液晶の PC 表示を解除し、本体側の操作を有効にします")
                Divider()
                Button("時計を Mac に合わせる") { model.syncClock() }
                    .disabled(!model.isConnected)
                Divider()
                Button("位置情報を付与…") { openGeoTag() }
                    .keyboardShortcut("g", modifiers: [.command, .shift])
                Button("保存先を開く") {
                    NSWorkspace.shared.open(model.effectiveDestination)
                }
            }
        }

        Window("位置情報を付与", id: "geotag") {
            GeoTagView()
        }
        .defaultSize(width: 700, height: 520)

        Settings {
            SettingsView()
                .environmentObject(model)
        }
    }
}
