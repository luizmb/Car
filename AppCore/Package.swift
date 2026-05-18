// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "AppCore",
    platforms: [.iOS(.v17), .watchOS(.v8)],
    products: [
        .library(name: "AppCore", targets: ["AppCore"])
    ],
    dependencies: [
        .package(url: "https://github.com/SwiftRex/SwiftRex.git", from: "0.8.12"),
        .package(url: "https://github.com/SwiftRex/SwiftRexMacros.git", branch: "master"),
        .package(url: "https://github.com/SwiftRex/AppLifecycleMiddleware.git", from: "0.1.0"),
        .package(url: "https://github.com/SwiftRex/BridgeMiddleware.git", from: "0.1.3"),
        .package(url: "https://github.com/SwiftRex/LoggerMiddleware.git", from: "0.3.9")
    ],
    targets: [
        .target(
            name: "AppCore",
            dependencies: [
                .product(name: "CombineRex", package: "SwiftRex"),
                "SwiftRexMacros",
                "AppLifecycleMiddleware",
                .product(name: "BridgeMiddlewareCombine", package: "BridgeMiddleware"),
                "LoggerMiddleware"
            ]
        ),
        .testTarget(name: "AppCoreTests", dependencies: ["AppCore"])
    ]
)
