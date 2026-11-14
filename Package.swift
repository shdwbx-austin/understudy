// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "cam4prog",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "Cam4Prog", targets: ["Cam4Prog"]),
        .library(name: "Cam4ProgCore", targets: ["Cam4ProgCore"]),
    ],
    targets: [
        // Pure logic: timecode math, LTC decode/encode, HyperDeck protocol, chase engine. Foundation only.
        .target(name: "Cam4ProgCore"),
        // macOS app: SwiftUI, Core Audio LTC input, Network.framework deck control.
        .executableTarget(name: "Cam4Prog", dependencies: ["Cam4ProgCore"]),
        .testTarget(name: "Cam4ProgCoreTests", dependencies: ["Cam4ProgCore"]),
    ]
)
