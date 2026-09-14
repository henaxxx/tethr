import SwiftUI
import TethrUI

/// 写真を画面いっぱいで確認するモード。
///
/// 横位置の写真は、端末を縦に持ったまま大きく見られるよう中身ごと 90 度回す。
/// 画像だけでなく操作部も一緒に回すので、端末を横に倒せば文字も操作方向も見た目どおりになる。
/// 縦位置の写真（カメラを縦に構えて撮ったカット）は回さず、縦のまま全面に出す。
///
/// 送りは横スワイプか左右の矢印。どちらも写真の向きに対して横で、端の写真では矢印を出さない。
struct ReviewView: View {
    @EnvironmentObject var session: CameraSession
    @Environment(\.dismiss) private var dismiss

    @State private var zoom: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var offsetAtStart: CGSize = .zero
    @State private var pinching = false
    /// 送りのために指で引いている量（写真の横方向）
    @State private var swipe: CGFloat = 0
    /// 送りのアニメーション中。重ねて送らない
    @State private var paging = false
    @State private var showChrome = true
    @State private var fullImage: UIImage?

    private var shots: [Shot] { session.shots }
    private var index: Int { shots.firstIndex { $0.id == session.selection } ?? 0 }
    private var shot: Shot? { shots.indices.contains(index) ? shots[index] : nil }
    private var image: UIImage? { fullImage ?? shot?.preview ?? shot?.thumbnail }

    /// 縦長の写真。回さずに出す
    private var upright: Bool {
        guard let image else { return false }
        return image.size.height > image.size.width
    }

    var body: some View {
        GeometryReader { geo in
            // 横長の写真は横長の座標系で組み立ててから、まとめて回す
            let size = upright ? geo.size : CGSize(width: geo.size.height, height: geo.size.width)
            ZStack {
                Color.black
                content(size: size, travel: max(geo.size.width, geo.size.height))
                    .frame(width: size.width, height: size.height)
                    .rotationEffect(.degrees(upright ? 0 : 90))
                    .frame(width: geo.size.width, height: geo.size.height)
            }
        }
        .ignoresSafeArea()
        .statusBarHidden()
        .task(id: session.selection) { await refresh() }
        // 取り込みが済んだら、端末内のファイルから大きな絵を作り直す
        .onChange(of: shot?.previewURL) { _, url in
            guard let url else { return }
            Task { fullImage = await Preview.load(url) }
        }
        // 確認モードでは露出計を出していないので、問い合わせも止める
        .onAppear { session.setPollingSuspended(true) }
        .onDisappear { session.setPollingSuspended(false) }
    }

    @ViewBuilder
    private func content(size: CGSize, travel: CGFloat) -> some View {
        ZStack {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: size.width, height: size.height)
                    .scaleEffect(zoom)
                    .offset(x: offset.width + swipe, y: offset.height)
            } else {
                ProgressView().tint(.white)
            }
        }
        .frame(width: size.width, height: size.height)
        .contentShape(Rectangle())
        .gesture(pinch)
        .simultaneousGesture(drag(width: size.width, travel: travel))
        .onTapGesture(count: 2) { toggleZoom() }
        .onTapGesture { withAnimation(.easeOut(duration: 0.15)) { showChrome.toggle() } }
        .overlay {
            if showChrome { chrome }
        }
    }

    private var chrome: some View {
        let insets = Self.safeAreaInsets
        // 回すときは端末の角丸とダイナミックアイランドが左右に来るので、左右を多めに逃がす。
        // 縦のまま出すときは、上下の安全領域を避ける
        let side: CGFloat = upright ? 12 : 46
        let top: CGFloat = upright ? insets.top : 0
        let bottom: CGFloat = upright ? max(insets.bottom, 12) + 12 : 28

        return VStack {
            HStack(spacing: 14) {
                Button { dismiss() } label: {
                    Image(systemName: "xmark").font(.system(size: 15, weight: .semibold))
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel(Text("閉じる"))
                if let shot {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(shot.name).font(.system(size: 13, weight: .medium))
                        Text("\(index + 1) / \(shots.count)  \(shot.sizeText)")
                            .font(.system(size: 12).monospacedDigit())
                            .foregroundStyle(Theme.dim)
                    }
                }
                Spacer()
                if let shot {
                    ImportButton(shot: shot)
                }
            }
            .padding(.horizontal, side)
            .padding(.top, top)
            .padding(.vertical, 8)
            .background(.black.opacity(0.55))

            Spacer()

            HStack {
                arrow("chevron.left", visible: index > 0) { step(-1) }
                Spacer()
                arrow("chevron.right", visible: index < shots.count - 1) { step(1) }
            }
            .padding(.horizontal, side)
            .padding(.bottom, bottom)
        }
        .foregroundStyle(.white)
        .tint(.white)
        .transition(.opacity)
    }

    /// 送りの矢印。行き先が無ければ出さない（場所は保ち、反対側の矢印が動かないようにする）
    private func arrow(_ symbol: String, visible: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 20, weight: .semibold))
                .frame(width: 48, height: 48)
                .glassCircle()
        }
        .opacity(visible ? 1 : 0)
        .allowsHitTesting(visible)
        .accessibilityHidden(!visible)
    }

    private static var keyWindow: UIWindow? {
        UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.keyWindow }.first
    }

    /// 全画面は安全領域を無視して描くので、避ける量は窓から読む
    private static var safeAreaInsets: UIEdgeInsets {
        keyWindow?.safeAreaInsets ?? UIEdgeInsets(top: 54, left: 0, bottom: 34, right: 0)
    }

    // MARK: 操作

    private var pinch: some Gesture {
        MagnifyGesture()
            .onChanged {
                pinching = true
                swipe = 0
                zoom = min(max($0.magnification, 1), 10)
            }
            .onEnded { _ in
                pinching = false
                if zoom <= 1.02 { withAnimation { zoom = 1; offset = .zero; offsetAtStart = .zero } }
            }
    }

    /// 拡大中は写真を動かし、等倍のときは横に引いて前後の写真へ送る
    private func drag(width: CGFloat, travel: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 8)
            .onChanged { v in
                guard !pinching else { return }
                if zoom > 1.02 {
                    offset = CGSize(width: offsetAtStart.width + v.translation.width,
                                    height: offsetAtStart.height + v.translation.height)
                    return
                }
                guard !paging else { return }
                let dx = v.translation.width
                let hasNeighbor = dx < 0 ? index < shots.count - 1 : index > 0
                // 行き先が無い側は重くして、端だと分かるようにする
                swipe = hasNeighbor ? dx : dx * 0.25
            }
            .onEnded { v in
                if zoom > 1.02 {
                    offsetAtStart = offset
                    return
                }
                guard !paging, !pinching else { return }
                // 横位置は幅が 900pt 近くあるので、割合だけで決めると引く量が長すぎる
                let moved = v.translation.width
                let flung = v.predictedEndTranslation.width
                let enough = min(width * 0.3, 110)
                let fling = min(width * 0.5, 220)
                let delta = (moved < -enough || flung < -fling) ? 1
                          : (moved > enough || flung > fling) ? -1 : 0
                guard delta != 0, shots.indices.contains(index + delta) else {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { swipe = 0 }
                    return
                }
                page(by: delta, travel: travel)
            }
    }

    private func toggleZoom() {
        withAnimation(.easeOut(duration: 0.2)) {
            if zoom > 1.02 { zoom = 1; offset = .zero } else { zoom = 3 }
        }
        offsetAtStart = offset
    }

    private func step(_ delta: Int) {
        guard !paging, shots.indices.contains(index + delta) else { return }
        let bounds = Self.keyWindow?.bounds.size ?? CGSize(width: 1000, height: 1000)
        page(by: delta, travel: max(bounds.width, bounds.height))
    }

    /// 今の写真を送る向きへ流し、次の写真を反対側から入れる
    private func page(by delta: Int, travel: CGFloat) {
        let next = shots[index + delta].id
        paging = true
        Haptics.select()
        withAnimation(.easeIn(duration: 0.12)) {
            swipe = -CGFloat(delta) * travel
        } completion: {
            var instant = Transaction()
            instant.disablesAnimations = true
            withTransaction(instant) {
                session.selection = next
                swipe = CGFloat(delta) * travel
            }
            withAnimation(.spring(response: 0.32, dampingFraction: 0.9)) {
                swipe = 0
            } completion: {
                paging = false
            }
        }
    }

    private func refresh() async {
        zoom = 1; offset = .zero; offsetAtStart = .zero
        fullImage = nil
        if let shot { session.requestPreview(for: shot) }
        guard let url = shot?.previewURL else { return }
        fullImage = await Preview.load(url)
    }
}
