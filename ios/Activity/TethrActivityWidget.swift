import ActivityKit
import SwiftUI
import WidgetKit

@main
struct TethrActivityBundle: WidgetBundle {
    var body: some Widget {
        TethrLiveActivity()
    }
}

/// アプリの琥珀色（TethrUI の Theme.amber と同じ値。拡張には TethrUI を入れない）
private let amber = Color(red: 0.847, green: 0.639, blue: 0.255)

/// カメラとのつながりを、ダイナミックアイランドとロック画面に出す
struct TethrLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: TethrActivityAttributes.self) { context in
            LockScreenView(name: context.attributes.cameraName, state: context.state, stale: context.isStale)
                .activityBackgroundTint(Color.black.opacity(0.78))
                .activitySystemActionForegroundColor(amber)
        } dynamicIsland: { context in
            let state = context.state
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label {
                        Text(context.attributes.cameraName).font(.system(size: 15, weight: .semibold))
                    } icon: {
                        Image(systemName: "camera.aperture").foregroundStyle(amber)
                    }
                    .padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    if let battery = state.battery {
                        Label("\(battery)%", systemImage: batterySymbol(battery))
                            .font(.system(size: 13).monospacedDigit())
                            .foregroundStyle(.secondary)
                            .padding(.trailing, 4)
                    }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    StatusDetail(state: state, stale: context.isStale)
                        .padding(.horizontal, 4)
                }
            } compactLeading: {
                CompactLeading(state: state)
            } compactTrailing: {
                CompactTrailing(state: state)
            } minimal: {
                CompactLeading(state: state)
            }
            .keylineTint(amber)
        }
    }
}

// MARK: - ダイナミックアイランド（小さい表示）

private struct CompactLeading: View {
    let state: TethrActivityAttributes.ContentState

    var body: some View {
        switch state.phase {
        case .loading, .importing:
            if let fraction = state.fraction {
                ProgressView(value: fraction)
                    .progressViewStyle(.circular)
                    .tint(amber)
            } else {
                Image(systemName: state.phase == .importing ? "arrow.down.circle" : "sdcard").foregroundStyle(amber)
            }
        case .paused:
            Image(systemName: "pause.circle.fill").foregroundStyle(.secondary)
        case .preparing, .connected:
            Image(systemName: "camera.aperture").foregroundStyle(amber)
        }
    }
}

private struct CompactTrailing: View {
    let state: TethrActivityAttributes.ContentState

    var body: some View {
        Group {
            switch state.phase {
            case .preparing:
                // 止まって見えないよう、経過時間を進める（アプリが止まっていてもシステムが数える）
                Text(timerInterval: state.since...Date.distantFuture, countsDown: false)
                    .frame(maxWidth: 44)
            case .loading, .importing:
                if let expected = state.expected {
                    Text("\(state.loaded)/\(expected)")
                } else {
                    Text("\(state.loaded)")
                }
            case .connected:
                Text("\(state.shots) 枚")
            case .paused:
                Text("休止")
            }
        }
        .font(.system(size: 13, weight: .medium).monospacedDigit())
        .foregroundStyle(state.phase == .paused ? .secondary : amber)
    }
}

// MARK: - 広げた表示とロック画面で共通の中身

private struct StatusDetail: View {
    let state: TethrActivityAttributes.ContentState
    let stale: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(title).font(.system(size: 14, weight: .medium))
                Spacer(minLength: 4)
                if state.phase == .preparing {
                    Text(timerInterval: state.since...Date.distantFuture, countsDown: false)
                        .font(.system(size: 13).monospacedDigit())
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.trailing)
                        .frame(maxWidth: 60, alignment: .trailing)
                } else if state.phase == .loading || state.phase == .importing, let expected = state.expected {
                    Text("\(state.loaded) / \(expected)")
                        .font(.system(size: 13).monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            if state.phase == .loading || state.phase == .importing, let fraction = state.fraction {
                ProgressView(value: fraction).tint(amber)
            }
            detail
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    private var title: LocalizedStringKey {
        if stale { return "Tethr を開くと再接続します" }
        switch state.phase {
        case .preparing: return "カードを確認中"
        case .loading: return "カードを読み込み中"
        case .connected: return "接続中"
        case .paused: return "接続を休ませています"
        case .importing: return "写真を取り込み中"
        }
    }

    @ViewBuilder
    private var detail: some View {
        if state.phase == .paused || stale {
            Text("アプリに戻ると、続きから始めます")
        } else if let keepUntil = state.keepUntil, keepUntil > Date() {
            // 背面で接続を保っている残り時間。過ぎたら電池のために休ませる
            HStack(spacing: 4) {
                Text("接続を休ませるまで")
                Text(timerInterval: Date()...keepUntil, countsDown: true)
                    .monospacedDigit()
                    .frame(maxWidth: 40, alignment: .leading)
            }
        } else if state.phase == .loading {
            Text("ホーム画面にいる間も、しばらく読み込みを続けます")
        } else if state.phase == .importing {
            Text("アプリに戻ると、残りを続けて取り込みます")
        } else if let lastShot = state.lastShot {
            Text("撮ったカット \(state.shots) 枚・最新 \(lastShot)")
        } else if state.phase == .preparing {
            Text("電源を入れた直後は、1 分ほどかかることがあります")
        } else {
            Text("シャッターを切ると、ここに届いた枚数が出ます")
        }
    }
}

private struct LockScreenView: View {
    let name: String
    let state: TethrActivityAttributes.ContentState
    let stale: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: state.phase == .paused ? "pause.circle.fill" : "camera.aperture")
                .font(.system(size: 26))
                .foregroundStyle(state.phase == .paused ? Color.secondary : amber)
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(name).font(.system(size: 15, weight: .semibold))
                    Spacer()
                    if let battery = state.battery {
                        Label("\(battery)%", systemImage: batterySymbol(battery))
                            .font(.system(size: 12).monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                StatusDetail(state: state, stale: stale)
            }
        }
        .foregroundStyle(.white)
        .padding(14)
    }
}

/// D300 は電池を 20% 刻みで返す
private func batterySymbol(_ level: Int) -> String {
    switch level {
    case ..<20: return "battery.0percent"
    case ..<45: return "battery.25percent"
    case ..<70: return "battery.50percent"
    case ..<95: return "battery.75percent"
    default: return "battery.100percent"
    }
}
