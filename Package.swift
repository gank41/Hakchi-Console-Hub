// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "SwiftHakchi",
    platforms: [
        .macOS(.v14)
    ],
    dependencies: [
        .package(url: "https://github.com/tsolomko/SWCompression.git", from: "4.8.0"),
    ],
    targets: [
        .target(name: "NativeLZO", path: "vendor/minilzo", sources: ["minilzo.c", "safe_decode.c", "safe_encode.c", "lzo999/src/lzo1x_9x.c"], publicHeadersPath: "include", cSettings: [.headerSearchPath("lzo999/include")]),
        .target(name: "SwiftHakchiCore", dependencies: ["NativeLZO"], path: "SwiftHakchiCore"),
        .testTarget(name: "SwiftHakchiCoreTests", dependencies: ["SwiftHakchiCore"]),
        .testTarget(name: "SwiftHakchiTests", dependencies: ["SwiftHakchi", "SwiftHakchiCore", "USBBridge"]),
        .target(
            name: "MbedCrypto",
            path: "vendor/mbedtls",
            sources: ["library/"],
            publicHeadersPath: "include",
            cSettings: [
                .define("MBEDTLS_CONFIG_FILE", to: "\"mbedtls/mbedtls_config.h\""),
            ]
        ),
        .target(
            name: "LibSSH2",
            dependencies: ["MbedCrypto"],
            path: "vendor/libssh2",
            sources: ["src/"],
            publicHeadersPath: "include",
            cSettings: [
                .define("LIBSSH2_MBEDTLS"),
                .define("HAVE_CONFIG_H"),
                .headerSearchPath("src"),
            ]
        ),
        .target(
            name: "USBBridge",
            dependencies: ["LibSSH2"],
            path: "USBBridge",
            sources: ["src"],
            publicHeadersPath: "include",
            linkerSettings: [
                .linkedFramework("IOKit"),
                .linkedFramework("CoreFoundation"),
            ]
        ),
        .executableTarget(
            name: "SwiftHakchi",
            dependencies: [
                "USBBridge",
                "SwiftHakchiCore",
                .product(name: "SWCompression", package: "SWCompression"),
            ],
            path: "SwiftHakchi",
            exclude: ["Resources/GameGenie"],
            resources: [
                .copy("Resources/fes1.bin"),
                .copy("Resources/snes-menu-launch"),
                .copy("Resources/SNESCompatibilityController.cfg"),
                .copy("Resources/SNESCompatibilityCore"),
                .copy("Resources/SNESCompatibilityFrontend"),
                .copy("Resources/SNESCompatibilityProbe"),
                .copy("Resources/SNESPortableHelpers"),
                .copy("Resources/basehmods.tar"),
                .copy("Resources/hakchi.hmod"),
                .copy("Resources/snescarts.xml"),
                .copy("Resources/nescarts.xml"),
                .copy("Resources/romfiles.xml"),
                .copy("Resources/genesis-metadata-v1.json"),
                .copy("Resources/AppIcon.icns"),
                .copy("Resources/AppIcons"),
                .copy("Resources/CheatCodes"),
                .copy("Resources/ThirdPartyLicenses"),
            ],
            linkerSettings: [
                .linkedFramework("IOKit"),
                .linkedFramework("CoreFoundation"),
            ]
        ),
    ]
)
