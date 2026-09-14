import SwiftUI

@main
struct TethrTouchApp: App {
    @StateObject private var session = CameraSession()
    @Environment(\.scenePhase) private var scenePhase

    init() {
        // 背面でも取り込みを続けるハンドラは、起動の途中で登録しておく決まり
        BatchImporter.registerBackgroundTask()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(session)
                .preferredColorScheme(.dark)
                .onChange(of: scenePhase) { _, phase in
                    // 背面に回っている間はカメラに問い合わせない
                    session.setPollingSuspended(phase != .active)
                    switch phase {
                    case .background: session.appDidEnterBackground()
                    case .active:
                        Interaction.installOnWindows()
                        session.appDidBecomeActive()
                    default: break
                    }
                }
        }
    }
}
