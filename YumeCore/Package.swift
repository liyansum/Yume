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
    dependencies: [
        .package(path: "../ThirdParty/PLzmaSDK"),
        .package(path: "../ThirdParty/MinizipNG")
    ],
    targets: [
        .target(name: "YumeDomain"),
        .target(
            name: "CYumeZlib",
            path: "Sources/CYumeZlib",
            publicHeadersPath: "include",
            linkerSettings: [.linkedLibrary("z")]
        ),
        .target(
            name: "YumeApplication",
            dependencies: ["YumeDomain"]
        ),
        .target(
            name: "CYumeRuntimeBridge",
            path: "Sources/CYumeRuntimeBridge",
            publicHeadersPath: "include"
        ),
        .target(
            name: "YumeInfrastructure",
            dependencies: [
                "YumeDomain",
                "YumeApplication",
                "CYumeZlib",
                .product(name: "CMinizipNG", package: "MinizipNG"),
                .product(name: "PLzmaSDK-Static", package: "PLzmaSDK")
            ]
        ),
        .target(
            name: "YumeEngineHost",
            dependencies: ["YumeDomain", "CYumeRuntimeBridge"]
        ),
        .testTarget(
            name: "YumeDomainTests",
            dependencies: ["YumeDomain"]
        ),
        .testTarget(
            name: "YumeApplicationTests",
            dependencies: ["YumeApplication", "YumeDomain"]
        ),
        .testTarget(
            name: "YumeInfrastructureTests",
            dependencies: [
                "YumeInfrastructure",
                "YumeApplication",
                "YumeDomain",
                .product(name: "PLzmaSDK", package: "PLzmaSDK")
            ]
        ),
        .testTarget(
            name: "YumeEngineHostTests",
            dependencies: ["YumeEngineHost", "YumeDomain"]
        )
    ]
)
