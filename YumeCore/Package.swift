// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "YumeCore",
    platforms: [
        .iOS(.v18),
        .macOS(.v15)
    ],
    products: [
        .library(name: "YumeDomain", targets: ["YumeDomain"]),
        .library(name: "YumeApplication", targets: ["YumeApplication"]),
        .library(name: "YumeInfrastructure", targets: ["YumeInfrastructure"]),
        .library(name: "YumeEngineHost", targets: ["YumeEngineHost"])
    ],
    targets: [
        .target(name: "YumeDomain"),
        .target(
            name: "YumeApplication",
            dependencies: ["YumeDomain"]
        ),
        .target(
            name: "YumeInfrastructure",
            dependencies: ["YumeDomain", "YumeApplication"]
        ),
        .target(
            name: "YumeEngineHost",
            dependencies: ["YumeDomain"]
        ),
        .testTarget(
            name: "YumeDomainTests",
            dependencies: ["YumeDomain"]
        ),
        .testTarget(
            name: "YumeApplicationTests",
            dependencies: ["YumeApplication", "YumeDomain"]
        )
    ]
)
