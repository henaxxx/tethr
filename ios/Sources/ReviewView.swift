import SwiftUI

/// 写真を画面いっぱいで確認するモード。
///
/// 端末を縦に持ったまま横位置の写真を大きく見るため、中身ごと 90 度回す。
/// 画像だけでなく操作部も一緒に回すので、端末を横に倒せば
/// 文字も操作方向も見た目どおりになる。
struct ReviewView: View {
    @EnvironmentObject var session: CameraSession
    @Environment(\.dismiss) private var dismiss

    @State private var zoom: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var offsetAtStart: CGSize = .zero
    @State private var showChrome = true
    @State private var fullImage: UIImage?
    @State private var downloading = false

    private var shots: [Shot] { session.shots }
    private var index: Int { shots.firstIndex { $0.id == session.selection } ?? 0 }
    private var shot: Shot? { shots.indices.contains(index) ? shots[index] : nil }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color.black.ignoresSafeArea()

                // 横長の座標系で組み立ててから、まとめて回す
                content(size: CGSize(width: geo.size.height, height: geo.size.width))
                    .frame(width: geo.size.height, height: geo.size.width)
                    .rotationEffect(.degrees(90))
                    .frame(width: geo.size.width, height: geo.size.height)
            }
        }
        .ignoresSafeArea()
        .statusBarHidden()
        .task(id: session.selection) { await refresh() }
        // 確認モードでは露出計を出していないので、問い合わせも止める
        .onAppear { session.setPollingSuspended(true) }
        .onDisappear { session.setPollingSuspended(false) }
    }

    @ViewBuilder
    private func content(size: CGSize) -> some View {
        ZStack {
            if let image = fullImage ?? shot?.preview ?? shot?.thumbnail {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: size.width, height: size.height)
                    .scaleEffect(zoom)
                    .offset(offset)
                    .gesture(pinch)
                    .simultaneousGesture(pan)
                    .onTapGesture(count: 2) { toggleZoom() }
                    .onTapGesture { withAnimation(.easeOut(duration: 0.15)) { showChrome.toggle() } }
            } else {
                ProgressView().tint(.white)
            }

            if showChrome { chrome }
        }
    }

    private var chrome: some View {
        VStack {
            HStack(spacing: 14) {
                Button { dismiss() } label: {
                    Image(systemName: "xmark").font(.system(size: 15, weight: .semibold))
                }
                if let shot {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(shot.name).font(.system(size: 13, weight: .medium))
                        Text("\(index + 1) / \(shots.count)  \(shot.sizeText)")
                            .font(.system(size: 10).monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if downloading {
                    ProgressView().controlSize(.small).tint(.white)
                } else if shot?.localURL == nil {
                    Button("取り込む") { download() }
                        .font(.system(size: 13, weight: .medium))
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                } else {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                }
            }
            // 回転させているぶん、端末の角丸とダイナミックアイランドに
            // 操作部が食い込みやすい。左右は多めに逃がす。
            .padding(.horizontal, 46)
            .padding(.vertical, 16)
            .background(.ultraThinMaterial)

            Spacer()

            HStack {
                Button { step(-1) } label: {
                    Image(systemName: "chevron.left").font(.system(size: 22, weight: .semibold))
                }
                .disabled(index <= 0)
                Spacer()
                Button { step(1) } label: {
                    Image(systemName: "chevron.right").font(.system(size: 22, weight: .semibold))
                }
                .disabled(index >= shots.count - 1)
            }
            .padding(.horizontal, 46)
            .padding(.bottom, 28)
        }
        .foregroundStyle(.white)
        .transition(.opacity)
    }

    // MARK: 操作

    private var pinch: some Gesture {
        MagnifyGesture()
            .onChanged { zoom = min(max($0.magnification, 1), 10) }
            .onEnded { _ in if zoom <= 1.02 { withAnimation { offset = .zero; offsetAtStart = .zero } } }
    }

    private var pan: some Gesture {
        DragGesture()
            .onChanged { v in
                guard zoom > 1.02 else { return }
                offset = CGSize(width: offsetAtStart.width + v.translation.width,
                                height: offsetAtStart.height + v.translation.height)
            }
            .onEnded { _ in offsetAtStart = offset }
    }

    private func toggleZoom() {
        withAnimation(.easeOut(duration: 0.2)) {
            if zoom > 1.02 { zoom = 1; offset = .zero } else { zoom = 3 }
        }
        offsetAtStart = offset
    }

    private func step(_ delta: Int) {
        let next = index + delta
        guard shots.indices.contains(next) else { return }
        Haptics.select()
        session.selection = shots[next].id
    }

    private func refresh() async {
        zoom = 1; offset = .zero; offsetAtStart = .zero
        fullImage = nil
        if let shot { session.requestPreview(for: shot) }
        guard let url = shot?.localURL else { return }
        fullImage = await Preview.load(url)
    }

    private func download() {
        guard let shot else { return }
        downloading = true
        Task {
            let url = await session.importShot(shot)
            downloading = false
            guard let url else { return }
            Haptics.success()
            fullImage = await Preview.load(url)
        }
    }
}
