// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CleanPlayer",
    platforms: [.iOS(.v17)],
    products: [.library(name: "CleanPlayer", targets: ["CleanPlayer"])],
    targets: [
        // ponytail: Swift 5 language mode. Strict concurrency would require
        // Sendable annotations across every AVFoundation/WebKit delegate
        // callback, which is orthogonal to the bugs being fixed here.
        // Upgrade path: drop swiftLanguageModes and work through the errors.
        .target(name: "CleanPlayer", swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(name: "CleanPlayerTests", dependencies: ["CleanPlayer"],
                    swiftSettings: [.swiftLanguageMode(.v5)]),
    ]
)
