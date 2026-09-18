// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SubscriptionBar",
    defaultLocalization: "en",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "SubscriptionBar", targets: ["SubscriptionBar"])],
    targets: [
        .target(name: "SubscriptionCore", resources: [.process("Resources")]),
        .executableTarget(name: "SubscriptionBar", dependencies: ["SubscriptionCore"]),
        .testTarget(name: "SubscriptionCoreTests", dependencies: ["SubscriptionCore"]),
        .testTarget(name: "SubscriptionBarTests", dependencies: ["SubscriptionBar"])
    ]
)
