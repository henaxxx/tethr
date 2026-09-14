import SwiftUI
import TethrUI
import UIKit

// MARK: - 複数選択モード

/// 下のコマの一覧でサムネイルを長押しすると出る。露出の操作とシャッターの場所に格子を並べ、
/// 選んだカットをまとめて写真アプリへ取り込む。
///
/// 長押しした指はいったん離してもらう（格子に入れ替わるとコマの位置が変わり、なぞり続けると狙わないコマを選ぶため）。
/// 格子では、タップで 1 枚ずつ、横になぞると続けて選べる（写真アプリと同じ）
struct SelectionPanel: View {
    @EnvironmentObject var session: CameraSession
    @ObservedObject var batch: BatchImporter
    @Binding var picked: Set<String>
    /// 長押しで選択を始めたコマ。格子をそこまで送り、一瞬光らせる
    let startName: String?
    let close: () -> Void

    private var shots: [Shot] { session.shots }

    private var allPickedHere: Bool {
        !shots.isEmpty && shots.allSatisfy { picked.contains($0.name) }
    }

    /// 選んだうち、まだ取り込んでいない枚数（テザーとカードの両方から数える）
    private var pendingCount: Int {
        picked.filter { session.shot(named: $0)?.imported == false }.count
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            SelectionGrid(
                shots: shots,
                picked: $picked,
                startName: startName,
                onFocus: { name in
                    guard let shot = session.shot(named: name), session.selection != shot.id else { return }
                    session.selection = shot.id
                },
                requestThumbnail: { session.requestThumbnail(for: $0) }
            )
            .disabled(batch.isRunning)
            footer
        }
        .onChange(of: batch.progress == nil) { _, finished in
            // 取り込みが終わったら、結果を少し見せてから撮影の画面に戻る
            guard finished, batch.lastResult != nil else { return }
            Task {
                try? await Task.sleep(for: .seconds(1.6))
                close()
            }
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            SourceToggle()
                .padding(.leading, 14)
            Spacer(minLength: 4)
            Button(allPickedHere ? "選択解除" : "すべて選択") {
                Haptics.select()
                if allPickedHere {
                    picked.subtract(shots.map(\.name))
                } else {
                    picked.formUnion(shots.map(\.name))
                }
            }
            .font(.system(size: 14, weight: .medium))
            .disabled(batch.isRunning || shots.isEmpty)
            Button("完了", action: close)
                .font(.system(size: 14, weight: .semibold))
                .padding(.trailing, 14)
                .disabled(batch.isRunning)
        }
        .frame(height: 56)
    }

    private var footer: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                if let result = batch.lastResult, !batch.isRunning {
                    Label(result, systemImage: "checkmark.circle.fill")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Theme.amber)
                        .lineLimit(2)
                } else if let progress = batch.progress {
                    Text(progress.waiting ? "戻ると続きから取り込みます" : "取り込み中 \(progress.done) / \(progress.total)")
                        .font(.system(size: 13, weight: .medium).monospacedDigit())
                    Text("画面は消えないようにしています")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.dim)
                } else {
                    Text("\(picked.count) 枚を選択")
                        .font(.system(size: 13, weight: .medium).monospacedDigit())
                    Button("未取り込みをすべて選ぶ") {
                        Haptics.select()
                        picked.formUnion(shots.filter { !$0.imported }.map(\.name))
                    }
                    .font(.system(size: 12))
                    .disabled(!shots.contains { !$0.imported })
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            BatchImportButton(batch: batch, pending: pendingCount) {
                batch.start(picked)
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 76)
    }
}

/// まとめて取り込むボタン。取り込み中はカプセルの中が枚数分満ちていき、押すと止める
private struct BatchImportButton: View {
    @ObservedObject var batch: BatchImporter
    let pending: Int
    let start: () -> Void

    var body: some View {
        let progress = batch.progress
        Button {
            Haptics.toggle()
            if progress != nil { batch.cancel() } else { start() }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: progress != nil ? "stop.fill" : "arrow.down.to.line")
                Text(progress != nil ? "止める" : "取り込む（\(pending)）")
                    .monospacedDigit()
            }
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(progress != nil ? Theme.text : (pending > 0 ? Theme.onAmber : Theme.dim))
            .padding(.horizontal, 18)
            .frame(height: 44)
            .background {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        if let progress {
                            Capsule().fill(Theme.surfaceRaised)
                            Rectangle()
                                .fill(Theme.amber.opacity(0.5))
                                .frame(width: geo.size.width * Double(progress.done) / Double(max(progress.total, 1)))
                                .animation(.easeOut(duration: 0.3), value: progress.done)
                        } else {
                            Capsule().fill(pending > 0 ? Theme.amber : Theme.surfaceRaised)
                        }
                    }
                    .clipShape(Capsule())
                }
            }
        }
        .buttonStyle(.plain)
        .disabled(progress == nil && pending == 0)
    }
}

// MARK: - 格子

/// 写真アプリと同じ選び方（タップで 1 枚、横になぞると続けて）ができるよう、UICollectionView で作る。
/// SwiftUI の ScrollView とドラッグを組み合わせると、縦のスクロールと選択がぶつかる
private struct SelectionGrid: UIViewRepresentable {
    let shots: [Shot]
    @Binding var picked: Set<String>
    let startName: String?
    let onFocus: (String) -> Void
    let requestThumbnail: (Shot) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> UICollectionView {
        let view = context.coordinator.makeCollectionView()
        context.coordinator.apply(shots: shots, picked: picked, animated: false)
        if let startName { context.coordinator.reveal(startName) }
        return view
    }

    func updateUIView(_ view: UICollectionView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.apply(shots: shots, picked: picked, animated: true)
        view.isUserInteractionEnabled = context.environment.isEnabled
    }

    @MainActor
    final class Coordinator: NSObject, UICollectionViewDelegate, UIGestureRecognizerDelegate {
        var parent: SelectionGrid
        private weak var collectionView: UICollectionView?
        private var dataSource: UICollectionViewDiffableDataSource<Int, String>!
        private var shotsByName: [String: Shot] = [:]
        private var order: [String] = []
        /// 光らせているコマ
        private var flashing: String?

        // なぞって選ぶ
        private var dragStart: Int?
        private var dragSelects = true
        private var dragBefore: Set<String> = []
        private var dragLocation: CGPoint?
        private var autoScroll: CADisplayLink?

        init(_ parent: SelectionGrid) {
            self.parent = parent
        }

        func makeCollectionView() -> UICollectionView {
            // 4 列。マスの間は 6pt（各マスの周りに 3pt ずつ）、マスは 3:2
            let item = NSCollectionLayoutItem(layoutSize: .init(widthDimension: .fractionalWidth(0.25), heightDimension: .fractionalHeight(1)))
            item.contentInsets = .init(top: 3, leading: 3, bottom: 3, trailing: 3)
            let row = NSCollectionLayoutGroup.horizontal(
                layoutSize: .init(widthDimension: .fractionalWidth(1), heightDimension: .fractionalWidth(1.0 / 6)),
                subitems: [item])
            let section = NSCollectionLayoutSection(group: row)
            section.contentInsets = .init(top: 0, leading: 11, bottom: 10, trailing: 11)
            let view = UICollectionView(frame: .zero, collectionViewLayout: UICollectionViewCompositionalLayout(section: section))
            view.backgroundColor = .clear
            view.allowsMultipleSelection = true
            view.delegate = self
            collectionView = view

            let registration = UICollectionView.CellRegistration<FixedSizeCell, String> { [weak self] cell, _, name in
                cell.configurationUpdateHandler = { [weak self] cell, state in
                    guard let self, let shot = self.shotsByName[name] else { return }
                    cell.contentConfiguration = UIHostingConfiguration {
                        GridCell(image: shot.thumbnail, located: shot.location != nil, imported: shot.imported,
                                 picked: state.isSelected, flashing: self.flashing == name)
                    }
                    .margins(.all, 0)
                }
            }
            dataSource = UICollectionViewDiffableDataSource(collectionView: view) { [weak self] view, indexPath, name in
                if let shot = self?.shotsByName[name] { self?.parent.requestThumbnail(shot) }
                return view.dequeueConfiguredReusableCell(using: registration, for: indexPath, item: name)
            }

            let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
            pan.delegate = self
            view.addGestureRecognizer(pan)
            // 縦のスクロールは、横なぞりでないと分かってから始める（なぞり始めで一覧が動かないように）
            view.panGestureRecognizer.require(toFail: pan)
            return view
        }

        /// 一覧と選択を SwiftUI 側の値に合わせる。サムネイルが届いたコマだけ描き直す
        func apply(shots: [Shot], picked: Set<String>, animated: Bool) {
            guard let collectionView else { return }
            let names = shots.map(\.name)
            let changed = shots.filter { shot in shotsByName[shot.name].map { $0 != shot } ?? false }.map(\.name)
            shotsByName = Dictionary(shots.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
            if names != order {
                order = names
                var snapshot = NSDiffableDataSourceSnapshot<Int, String>()
                snapshot.appendSections([0])
                snapshot.appendItems(names)
                dataSource.apply(snapshot, animatingDifferences: animated)
            } else if !changed.isEmpty {
                var snapshot = dataSource.snapshot()
                snapshot.reconfigureItems(changed)
                dataSource.apply(snapshot, animatingDifferences: false)
            }
            // 選択は SwiftUI 側（テザーとカードをまたいで持つ）が正
            for (index, name) in order.enumerated() {
                let indexPath = IndexPath(item: index, section: 0)
                let selected = collectionView.indexPathsForSelectedItems?.contains(indexPath) ?? false
                if picked.contains(name), !selected {
                    collectionView.selectItem(at: indexPath, animated: false, scrollPosition: [])
                } else if !picked.contains(name), selected {
                    collectionView.deselectItem(at: indexPath, animated: false)
                }
            }
        }

        /// 長押しで始めたコマを見える位置へ送り、一瞬光らせる
        func reveal(_ name: String) {
            DispatchQueue.main.async { [weak self] in
                guard let self, let collectionView = self.collectionView,
                      let index = self.order.firstIndex(of: name) else { return }
                collectionView.layoutIfNeeded()
                collectionView.scrollToItem(at: IndexPath(item: index, section: 0), at: .centeredVertically, animated: false)
                self.setFlashing(name)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in self?.setFlashing(nil) }
            }
        }

        private func setFlashing(_ name: String?) {
            let previous = flashing
            flashing = name
            var snapshot = dataSource.snapshot()
            let items = [previous, name].compactMap { $0 }.filter { snapshot.indexOfItem($0) != nil }
            guard !items.isEmpty else { return }
            snapshot.reconfigureItems(items)
            dataSource.apply(snapshot, animatingDifferences: false)
        }

        private func publish() {
            guard let collectionView else { return }
            let onScreen = Set((collectionView.indexPathsForSelectedItems ?? []).compactMap { order.indices.contains($0.item) ? order[$0.item] : nil })
            // 別の一覧（テザーとカード）で選んだものは残す
            var next = parent.picked.subtracting(order)
            next.formUnion(onScreen)
            if next != parent.picked { parent.picked = next }
        }

        // MARK: タップ

        func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
            Haptics.select()
            parent.onFocus(order[indexPath.item])
            publish()
        }

        func collectionView(_ collectionView: UICollectionView, didDeselectItemAt indexPath: IndexPath) {
            Haptics.select()
            parent.onFocus(order[indexPath.item])
            publish()
        }

        // MARK: なぞって選ぶ

        /// 横に動き始めたときだけ選択として扱う。縦は一覧のスクロールに任せる
        func gestureRecognizerShouldBegin(_ recognizer: UIGestureRecognizer) -> Bool {
            guard let pan = recognizer as? UIPanGestureRecognizer, let view = pan.view else { return false }
            let velocity = pan.velocity(in: view)
            return abs(velocity.x) > abs(velocity.y) * 1.2
        }

        @objc private func handlePan(_ pan: UIPanGestureRecognizer) {
            guard let collectionView else { return }
            let location = pan.location(in: collectionView)
            switch pan.state {
            case .began:
                guard let indexPath = nearestIndexPath(at: location) else { return }
                dragStart = indexPath.item
                dragBefore = Set((collectionView.indexPathsForSelectedItems ?? []).map { order[$0.item] })
                // 始めたコマが選ばれていなければ選んでいき、選ばれていれば外していく（写真アプリと同じ）
                dragSelects = !dragBefore.contains(order[indexPath.item])
                dragLocation = location
                updateDrag(to: indexPath.item)
                startAutoScroll()
            case .changed:
                dragLocation = location
                if let indexPath = nearestIndexPath(at: location) { updateDrag(to: indexPath.item) }
            default:
                stopAutoScroll()
                dragStart = nil
                dragLocation = nil
                publish()
            }
        }

        private func updateDrag(to end: Int) {
            guard let collectionView, let start = dragStart else { return }
            let range = min(start, end)...max(start, end)
            for (index, name) in order.enumerated() {
                let indexPath = IndexPath(item: index, section: 0)
                let want = range.contains(index) ? dragSelects : dragBefore.contains(name)
                let selected = collectionView.indexPathsForSelectedItems?.contains(indexPath) ?? false
                if want, !selected {
                    collectionView.selectItem(at: indexPath, animated: false, scrollPosition: [])
                    Haptics.select()
                } else if !want, selected {
                    collectionView.deselectItem(at: indexPath, animated: false)
                }
            }
            parent.onFocus(order[end])
            publish()
        }

        /// 行と行のすき間でもコマを外さないよう、いちばん近いコマを取る
        private func nearestIndexPath(at point: CGPoint) -> IndexPath? {
            guard let collectionView else { return nil }
            if let hit = collectionView.indexPathForItem(at: point) { return hit }
            return collectionView.indexPathsForVisibleItems.min { a, b in
                distance(collectionView.layoutAttributesForItem(at: a)?.center, point)
                    < distance(collectionView.layoutAttributesForItem(at: b)?.center, point)
            }
        }

        private func distance(_ a: CGPoint?, _ b: CGPoint) -> CGFloat {
            guard let a else { return .greatestFiniteMagnitude }
            return hypot(a.x - b.x, a.y - b.y)
        }

        /// 指が一覧の上端・下端に近づいたら、その向きに送り続ける
        private func startAutoScroll() {
            stopAutoScroll()
            let link = CADisplayLink(target: self, selector: #selector(tickAutoScroll))
            link.add(to: .main, forMode: .common)
            autoScroll = link
        }

        private func stopAutoScroll() {
            autoScroll?.invalidate()
            autoScroll = nil
        }

        @objc private func tickAutoScroll() {
            guard let collectionView, let location = dragLocation else { return }
            let visible = collectionView.bounds
            let edge: CGFloat = 36
            var delta: CGFloat = 0
            if location.y < visible.minY + edge { delta = -(visible.minY + edge - location.y) / 4 }
            if location.y > visible.maxY - edge { delta = (location.y - (visible.maxY - edge)) / 4 }
            guard delta != 0 else { return }
            let maxY = max(0, collectionView.contentSize.height - visible.height + collectionView.adjustedContentInset.bottom)
            let y = min(max(collectionView.contentOffset.y + delta, -collectionView.adjustedContentInset.top), maxY)
            guard y != collectionView.contentOffset.y else { return }
            collectionView.contentOffset.y = y
            dragLocation = CGPoint(x: location.x, y: location.y + (y - visible.minY))
            if let indexPath = nearestIndexPath(at: dragLocation!) { updateDrag(to: indexPath.item) }
        }
    }
}

/// 大きさは格子が決める。SwiftUI の中身に合わせて伸び縮みさせない
/// （画像の元の大きさでマスが広がり、隣と重なった）
private final class FixedSizeCell: UICollectionViewCell {
    override func preferredLayoutAttributesFitting(_ attributes: UICollectionViewLayoutAttributes) -> UICollectionViewLayoutAttributes {
        attributes
    }
}

/// 格子の 1 マス。表示に使う値だけを受け取る
private struct GridCell: View {
    let image: UIImage?
    let located: Bool
    let imported: Bool
    let picked: Bool
    let flashing: Bool

    var body: some View {
        Color.clear
            .overlay {
                if let image {
                    Image(uiImage: image).resizable().aspectRatio(contentMode: .fill)
                } else {
                    Rectangle().fill(Theme.surfaceRaised)
                    ProgressView().controlSize(.mini).tint(Theme.dim)
                }
            }
            .overlay {
                if picked { Color.black.opacity(0.25) }
            }
            .clipped()
        .overlay(alignment: .topTrailing) {
            if located {
                Image(systemName: "location.fill")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.6), radius: 1.5)
                    .padding(4)
            }
        }
        .overlay(alignment: .bottomLeading) {
            if imported {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.onAmber, Theme.amber)
                    .padding(3)
            }
        }
        .overlay(alignment: .bottomTrailing) {
            Image(systemName: picked ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 18, weight: picked ? .regular : .light))
                .foregroundStyle(picked ? AnyShapeStyle(Theme.amber) : AnyShapeStyle(Color.white.opacity(0.8)))
                .background(Circle().fill(picked ? Theme.onAmber : Color.black.opacity(0.15)).padding(2))
                .shadow(color: .black.opacity(0.4), radius: 1.5)
                .padding(4)
        }
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(picked || flashing ? Theme.amber : .clear, lineWidth: flashing ? 3 : 2)
        )
        .shadow(color: flashing ? Theme.amber.opacity(0.7) : .clear, radius: 8)
        .animation(.easeOut(duration: 0.25), value: flashing)
    }
}
