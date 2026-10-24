// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "FrameFold",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "FrameFold",
            path: "Sources/FrameFold",
            linkerSettings: [
                .linkedFramework("ImageCaptureCore"),
                .linkedFramework("Photos"),
                .linkedFramework("Vision"),
                .linkedFramework("AVKit"),
            ]
        )
    ]
)
