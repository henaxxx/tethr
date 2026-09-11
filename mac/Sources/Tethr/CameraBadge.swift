import SwiftUI

/// 接続中のカメラとレンズを示すカード。
struct CameraBadge: View {
    @EnvironmentObject var model: SessionModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(model.modelName)
                    .font(.system(size: 22, weight: .semibold, design: .rounded))
                if let fw = model.deviceInfo["deviceversion"] {
                    Text(fw)
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 3))
                }
                Spacer()
            }

            if let serial = model.deviceInfo["serialnumber"] {
                Text("S/N \(serial)")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }

            Divider().padding(.vertical, 8)

            if let lens = model.lensDescription {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "camera.aperture")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .frame(width: 16)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(lens)
                            .font(.system(size: 12, weight: .medium))
                            .fixedSize(horizontal: false, vertical: true)
                        if let focal = model.currentFocalLength {
                            Text("現在 \(focal)")
                                .font(.system(size: 10).monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer(minLength: 0)
                }
            } else if let focal = model.currentFocalLength {
                // レンズ名が取れないときは、確かな情報である焦点距離だけを出す
                HStack(spacing: 8) {
                    Image(systemName: "camera.aperture")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .frame(width: 16)
                    Text("焦点距離").font(.system(size: 11)).foregroundStyle(.secondary)
                    Spacer()
                    Text(focal)
                        .font(.system(size: 12, weight: .medium).monospacedDigit())
                }
            }

            if let pct = model.batteryPercent {
                Divider().padding(.vertical, 8)
                BatteryGauge(percent: pct)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(nsColor: .controlBackgroundColor))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.separator, lineWidth: 1))
        )
    }
}

struct BatteryGauge: View {
    let percent: Int

    private var color: Color {
        if percent <= 15 { return .red }
        if percent <= 35 { return .orange }
        return .green
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "battery.100")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .frame(width: 16)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(.quaternary)
                    Capsule()
                        .fill(color)
                        .frame(width: geo.size.width * CGFloat(percent) / 100)
                        .animation(.easeOut(duration: 0.25), value: percent)
                }
            }
            .frame(height: 6)
            Text("\(percent)%")
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 34, alignment: .trailing)
        }
    }
}
