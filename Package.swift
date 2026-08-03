// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "DACMatch",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "DACMatch", targets: ["DACMatch"])
    ],
    targets: [
        .executableTarget(
            name: "DACMatch",
            path: "Sources/DACMatch"
        ),
        .testTarget(
            name: "DACMatchTests",
            dependencies: ["DACMatch"],
            path: "Tests/DACMatchTests"
        )
    ]
)
