// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "Libarchive",
    platforms: [
        .iOS(.v18),
        .macOS(.v15)
    ],
    products: [
        .library(name: "CLibarchive", type: .static, targets: ["CLibarchive"])
    ],
    targets: [
        .target(
            name: "CLibarchive",
            path: "Sources/CLibarchive",
            publicHeadersPath: "include",
            cSettings: [
                .headerSearchPath("."),
                .headerSearchPath("include"),
                .define("HAVE_CONFIG_H"),
                .define("_FILE_OFFSET_BITS", to: "64"),
                .define("_POSIX_C_SOURCE", to: "200809L", .when(platforms: [.linux])),
                .define("_DEFAULT_SOURCE", .when(platforms: [.linux]))
            ],
            linkerSettings: [
                .linkedLibrary("z")
            ]
        )
    ],
    cLanguageStandard: .c11
)
