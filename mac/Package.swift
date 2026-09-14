// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Tethr",
    platforms: [.macOS("26.0")],
    dependencies: [
        // iOS 版と共有する、生の PTP 命令でカメラとやり取りする部品
        .package(path: "../TethrKit"),
    ],
    targets: [
        .executableTarget(
            name: "Tethr",
            dependencies: ["TethrKit"],
            path: "Sources/Tethr",
            swiftSettings: [
                .swiftLanguageMode(.v5),
            ]
        ),
    ]
)
