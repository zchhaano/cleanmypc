// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "AtlasTesting",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "AtlasRecoveryCrashHarness", targets: ["AtlasRecoveryCrashHarness"]),
        .library(name: "AtlasTestingSupport", targets: ["AtlasTestingSupport"]),
    ],
    dependencies: [
        .package(path: "../Packages"),
    ],
    targets: [
        .executableTarget(name: "AtlasRecoveryCrashHarness", dependencies: [
            .product(name: "AtlasInfrastructure", package: "Packages"),
            .product(name: "AtlasFileSafety", package: "Packages"),
            .product(name: "AtlasDomain", package: "Packages")
        ], path: "AtlasRecoveryCrashHarness/Sources/AtlasRecoveryCrashHarness"),
        .target(
            name: "AtlasTestingSupport",
            dependencies: [
                .product(name: "AtlasApplication", package: "Packages"),
                .product(name: "AtlasDomain", package: "Packages"),
                .product(name: "AtlasProtocol", package: "Packages"),
            ],
            path: "AtlasTestingSupport/Sources/AtlasTestingSupport"
        ),
    ]
)
