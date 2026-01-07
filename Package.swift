// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "CamBar",
    platforms: [
        .macOS(.v14),
    ],
    targets: [
        .executableTarget(
            name: "CamBar",
            path: "Sources/CamBar"),
        .testTarget(
            name: "CamBarTests",
            path: "Tests/CamBarTests")
    ]
)
