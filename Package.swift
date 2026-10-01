// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "TheosStudio",
    platforms: [
        .iOS(.v15),
        .macOS(.v12),
    ],
    products: [
        .library(name: "TheosStudioCore", targets: ["TheosStudioCore"]),
        .executable(name: "theosstudio", targets: ["TheosStudioCLI"]),
    ],
    targets: [
        .target(name: "TheosStudioCore"),
        .executableTarget(
            name: "TheosStudioCLI",
            dependencies: ["TheosStudioCore"]
        ),
        .testTarget(
            name: "TheosStudioCoreTests",
            dependencies: ["TheosStudioCore"]
        ),
    ]
)
