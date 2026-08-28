// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "MinizipNG",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [
        .library(name: "CMinizipNG", type: .static, targets: ["CMinizipNG"])
    ],
    targets: [
        .target(
            name: "CMinizipNG",
            path: "Sources/CMinizipNG",
            publicHeadersPath: ".",
            cSettings: [
                .define("HAVE_ZLIB"),
                .define("ZLIB_COMPAT"),
                .define("HAVE_PKCRYPT"),
                .define("HAVE_WZAES"),
                .define("_POSIX_C_SOURCE", to: "200809L", .when(platforms: [.linux])),
                .define("_DEFAULT_SOURCE", .when(platforms: [.linux])),
                // The Linux development image exposes its OpenSSL 3 headers
                // through the Node toolchain. Apple builds use CommonCrypto.
                .unsafeFlags(["-I/usr/include/node"], .when(platforms: [.linux]))
            ],
            linkerSettings: [
                .linkedLibrary("z"),
                .unsafeFlags(["-l:libcrypto.so.3"], .when(platforms: [.linux])),
                .linkedFramework("CoreFoundation", .when(platforms: [.iOS, .macOS])),
                .linkedFramework("Security", .when(platforms: [.iOS, .macOS]))
            ]
        )
    ],
    cLanguageStandard: .c11
)
