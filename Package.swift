// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "HiddenBar",
    platforms: [.macOS("27.0")],
    targets: [
        .executableTarget(name: "HiddenBar"),
    ]
)
