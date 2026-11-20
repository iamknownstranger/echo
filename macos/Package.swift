// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "EchoMusic",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "EchoMusic", targets: ["EchoMusic"])],
    targets: [
        .systemLibrary(name: "CZlib"),
        .executableTarget(name: "EchoMusic", dependencies: ["CZlib"], swiftSettings: [.enableUpcomingFeature("BareSlashRegexLiterals")]),
        .testTarget(name: "EchoMusicTests", dependencies: ["EchoMusic"])
    ]
)
