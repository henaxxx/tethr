// swift-tools-version: 6.0
import PackageDescription

// iOS 版と Mac 版が共有する、カメラとのやり取りの部品。
// どちらも ImageCaptureCore の生の PTP 命令でカメラに届くので、命令の組み立て・設定値の読み方・
// NEF の解析・機種ごとの注意（送ってはいけない命令）を一か所に置く。
let package = Package(
    name: "TethrKit",
    platforms: [.iOS("17.0"), .macOS("26.0")],
    products: [
        .library(name: "TethrKit", targets: ["TethrKit"]),
    ],
    targets: [
        .target(
            name: "TethrKit",
            path: "Sources/TethrKit",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
