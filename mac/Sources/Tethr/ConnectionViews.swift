import SwiftUI
import TethrUI

/// カメラは挿さっているが、まだ操作できないあいだの全面表示。
///
/// 電源を入れた直後は、macOS がカメラを知らせてくるまで 40 秒ほど何も起きない（D300 で 44 秒）。
/// その間「未接続」と出していたら、つながっていないと誤解された。
/// 経過時間を 1 秒ごとに進めて、待っていること・止まっていないことを伝える
struct WarmupOverlay: View {
    @EnvironmentObject var model: SessionModel

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let elapsed = model.warmupSince.map { max(0, context.date.timeIntervalSince($0)) } ?? 0
            PreparingOverlay(
                title: title,
                detail: detail(elapsed),
                footer: Text(Duration.seconds(Int(elapsed)).formatted(.time(pattern: .minuteSecond)))
            )
        }
    }

    private var title: Text {
        switch model.warmup {
        case .system(let name)?: Text("\(name) を準備しています")
        case .card?, nil: Text("カードを確認中")
        }
    }

    private func detail(_ elapsed: TimeInterval) -> Text {
        // ふだんは 1 分かからない。2 分を過ぎたら、待つより挿し直したほうが早い
        if elapsed > 120 {
            return Text("時間がかかっています。つながらないときは、USB ケーブルを挿し直すか、カメラの電源を入れ直してください")
        }
        return Text("電源を入れた直後は、つながるまで 1 分ほどかかることがあります")
    }
}

/// USB にカメラがいないあいだ。失敗ではなく、挿せば自動でつながることを伝える
struct CameraWaitView: View {
    /// 外れた理由など
    let note: String?

    var body: some View {
        VStack(spacing: 0) {
            Image(systemName: "cable.connector.horizontal")
                .font(.system(size: 40, weight: .ultraLight))
                .foregroundStyle(Theme.dim)
                .symbolEffect(.pulse, options: .repeating)
                .padding(.bottom, 22)
            if let note {
                Text(note)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.amber)
                    .padding(.bottom, 8)
            }
            Text("カメラを待っています")
                .font(.system(size: 18, weight: .semibold, design: .rounded))
                .padding(.bottom, 6)
            Text("USB でつないで、カメラの電源を入れてください。見つかると自動でつながります")
                .font(.system(size: 13))
                .foregroundStyle(Theme.dim)
                .multilineTextAlignment(.center)
        }
        .padding(24)
    }
}

/// カードの一覧が出そろうまで。届いた順に格子へ足すと上の段が入れ替わり続け、
/// サムネイルも後回しなので、止まったように見えた。数と進み具合だけを出し、そろってから並べる
struct CardLoadingView: View {
    let count: Int
    let expected: Int?

    var body: some View {
        VStack(spacing: 0) {
            Image(systemName: "sdcard")
                .font(.system(size: 36, weight: .ultraLight))
                .foregroundStyle(Theme.dim)
                .padding(.bottom, 22)
            Text("カードを読み込んでいます")
                .font(.system(size: 18, weight: .semibold, design: .rounded))
                .padding(.bottom, 16)
            if let expected, expected > 0 {
                ProgressView(value: Double(min(count, expected)), total: Double(expected))
                    .tint(Theme.amber)
                    .frame(width: 280)
                    .padding(.bottom, 8)
                Text("\(count) / \(expected) 件")
                    .font(.system(size: 13).monospacedDigit())
                    .foregroundStyle(Theme.dim)
            } else {
                ProgressView()
                    .controlSize(.small)
                    .padding(.bottom, 8)
                Text("\(count) 件")
                    .font(.system(size: 13).monospacedDigit())
                    .foregroundStyle(Theme.dim)
            }
            Text("読み終えると一覧を表示します")
                .font(.system(size: 12))
                .foregroundStyle(Theme.dimmer)
                .padding(.top, 14)
        }
        .padding(24)
    }
}
