// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "LaunchSpike",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "LaunchSpike",
            path: "Sources/LaunchSpike"
        )
    ]
)
