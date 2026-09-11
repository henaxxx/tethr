import SwiftUI

@main
struct TethrProbeApp: App {
    @StateObject private var probe = CameraProbe()

    var body: some Scene {
        WindowGroup {
            ContentView().environmentObject(probe)
        }
    }
}
