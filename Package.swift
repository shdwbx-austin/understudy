// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "understudy",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "Understudy", targets: ["Understudy"]),
        .library(name: "UnderstudyCore", targets: ["UnderstudyCore"]),
    ],
    targets: [
        // Pure logic: timecode math, LTC decode/encode, HyperDeck protocol, chase engine. Foundation only.
        .target(name: "UnderstudyCore"),
        // macOS app: SwiftUI, Core Audio LTC input, Network.framework deck control.
        .executableTarget(name: "Understudy", dependencies: ["UnderstudyCore"]),
        .testTarget(name: "UnderstudyCoreTests", dependencies: ["UnderstudyCore"]),
    ]
)
