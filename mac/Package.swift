// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Tethr",
    platforms: [.macOS("26.0")],
    targets: [
        // libgphoto2 への薄い C シム。Swift から扱いにくい部分だけを吸収する。
        .target(
            name: "CGPhoto",
            path: "Sources/CGPhoto",
            cSettings: [.unsafeFlags(["-I/opt/homebrew/include"])],
            linkerSettings: [
                .unsafeFlags(["-L/opt/homebrew/lib"]),
                .linkedLibrary("gphoto2"),
                .linkedLibrary("gphoto2_port"),
            ]
        ),
        .executableTarget(
            name: "Tethr",
            dependencies: ["CGPhoto"],
            path: "Sources/Tethr",
            swiftSettings: [
                .swiftLanguageMode(.v5),
                .unsafeFlags(["-Xcc", "-I/opt/homebrew/include"]),
            ]
        ),
    ]
)
