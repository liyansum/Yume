// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "PLzmaSDK",
    products: [
        .library(name: "PLzmaSDK", targets: ["PLzmaSDK"]),
        .library(name: "PLzmaSDK-Static", type: .static, targets: ["PLzmaSDK"]),
        .library(name: "PLzmaSDK-Dynamic", type: .dynamic, targets: ["PLzmaSDK"])
    ],
    targets: [
        .target(name: "libplzma",
                path: "src",
                cSettings: [
                    .define("LIBPLZMA_VERSION_BUILD", to: "1448"),
                    .define("_POSIX_C_SOURCE", to: "200112L", .when(platforms: [.linux])),
                    .unsafeFlags(["-fPIC"])
                ],
                cxxSettings: [
                    .define("LIBPLZMA_VERSION_BUILD", to: "1448"),
                    .unsafeFlags(["-fPIC", "-fno-rtti"])
                ]),
        .target(name: "PLzmaSDK",
                dependencies: [
                    .target(name: "libplzma")
                ],
                path: "swift",
                resources: [
                    .copy("PrivacyInfo.xcprivacy")
                ])
    ],
    swiftLanguageModes: [.v5, .v6],
    cLanguageStandard: .c11,
    cxxLanguageStandard: .cxx11
)
