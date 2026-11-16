// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "understudy",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "Understudy", targets: ["Understudy"]),
        .library(name: "UnderstudyCore", targets: ["UnderstudyCore"]),
    ],
    dependencies: [
        // Auto-updates from GitHub Releases (appcast.xml attached to each release).
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0"),
    ],
    targets: [
        // Pure logic: timecode math, LTC decode/encode, HyperDeck protocol, chase engine. Foundation only.
        .target(name: "UnderstudyCore"),
        // macOS app: SwiftUI, Core Audio LTC input, Network.framework deck control.
        .executableTarget(name: "Understudy", dependencies: [
            "UnderstudyCore",
            .product(name: "Sparkle", package: "Sparkle"),
        ]),
        .testTarget(name: "UnderstudyCoreTests", dependencies: ["UnderstudyCore"]),
    ]
)
