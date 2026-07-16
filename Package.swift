// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "CamBar",
    platforms: [
        .macOS(.v27),
    ],
    targets: [
        .target(
            name: "CamBarCore",
            path: "Sources/CamBarCore"
        ),
        .executableTarget(
            name: "CamBar",
            dependencies: ["CamBarCore"],
            path: "Sources/CamBar"
        ),
        .testTarget(
            name: "CamBarTests",
            dependencies: ["CamBarCore"],
            path: "Tests/CamBarTests"
        )
    ]
)
