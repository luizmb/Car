// swift-tools-version: 6.3
import PackageDescription

let sharedFP: [Target.Dependency] = [
    .product(name: "FP",       package: "FP"),
    .product(name: "FPMacros", package: "FP"),
]

let sharedSwiftRex: [Target.Dependency] = [
    .product(name: "SwiftRex",                    package: "SwiftRex"),
    .product(name: "SwiftRex.SwiftUI",            package: "SwiftRex"),
    .product(name: "SwiftRex.Architecture",       package: "SwiftRex"),
    .product(name: "SwiftRex.Operators",          package: "SwiftRex"),
    .product(name: "SwiftRex.ReactiveConcurrency", package: "SwiftRex"),
]

let sharedRC: [Target.Dependency] = [
    .product(name: "ReactiveConcurrency", package: "ReactiveConcurrency"),
]

let package = Package(
    name: "SpeedJarvis",
    platforms: [.iOS(.v26), .macOS(.v14)],
    products: [
        .library(name: "AppDomain",              targets: ["AppDomain"]),
        .library(name: "SpeedMonitorFeature", targets: ["SpeedMonitorFeature"]),
        .library(name: "AppCore",             targets: ["AppCore"]),
    ],
    dependencies: [
        .package(url: "https://github.com/SwiftRex/SwiftRex.git", branch: "main", traits: ["ReactiveConcurrency"]),
        .package(url: "https://github.com/luizmb/FP.git",                  from: "2.2.0"),
        .package(url: "https://github.com/luizmb/ReactiveConcurrency.git", from: "1.1.0"),
        .package(url: "https://github.com/luizmb/NetworkTools.git", from: "0.8.0"),
    ],
    targets: [

        // MARK: - Pure domain types and business logic (no side-effects)

        .target(
            name: "AppDomain",
            dependencies: sharedFP,
            path: "Sources/AppDomain"
        ),

        // MARK: - SpeedMonitor feature (behavior, view, content)

        .target(
            name: "SpeedMonitorFeature",
            dependencies: ["AppDomain"] + sharedFP + sharedSwiftRex + sharedRC,
            path: "Sources/SpeedMonitorFeature",
            resources: [.process("Assets.xcassets")]
        ),

        // MARK: - App wiring (routes, store, world, networking)

        .target(
            name: "AppCore",
            dependencies: [
                "AppDomain",
                "SpeedMonitorFeature",
                .product(name: "Core",          package: "NetworkTools"),
                .product(name: "NetworkClient", package: "NetworkTools"),
            ] + sharedFP + sharedSwiftRex + sharedRC,
            path: "Sources/AppCore"
        ),

        // MARK: - Tests

        .testTarget(
            name: "AppDomainTests",
            dependencies: ["AppDomain"],
            path: "Tests/AppDomainTests"
        ),
        .testTarget(
            name: "SpeedMonitorFeatureTests",
            dependencies: ["SpeedMonitorFeature"],
            path: "Tests/SpeedMonitorFeatureTests"
        ),
        .testTarget(
            name: "AppCoreTests",
            dependencies: ["AppCore"],
            path: "Tests/AppCoreTests"
        ),
    ],
    swiftLanguageModes: [.v5]
)
