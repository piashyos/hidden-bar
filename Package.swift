// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "HiddenBar",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "HiddenBar"),
    ]
)
