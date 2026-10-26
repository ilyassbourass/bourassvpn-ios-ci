// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "BourassEngine",
    platforms: [.macOS(.v13), .iOS(.v15)],
    products: [
        .library(name: "BourassEngine", targets: ["BourassEngine"]),
        .executable(name: "BourassCLI", targets: ["BourassCLI"]),
    ],
    targets: [
        .target(
            name: "CZstd",
            path: "Sources/CZstd",
            publicHeadersPath: "include",
            cSettings: [.define("ZSTD_LEGACY_SUPPORT", to: "0")]
        ),
        .target(name: "BourassEngine", dependencies: ["CZstd"]),
        .executableTarget(
            name: "BourassCLI",
            dependencies: ["BourassEngine"],
            path: "Tools/BourassCLI"
        ),
        .testTarget(
            name: "BourassEngineTests",
            dependencies: ["BourassEngine"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
