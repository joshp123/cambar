// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "CamBar",
    platforms: [
        .macOS(.v27),
    ],
    dependencies: [
        .package(path: "Vendor/IPCamKit"),
    ],
    targets: [
        .target(
            name: "CamBarCore",
            path: "Sources/CamBarCore"
        ),
        .executableTarget(
            name: "CamBar",
            dependencies: [
                "CamBarCore",
                .product(name: "IPCamKit", package: "IPCamKit"),
            ],
            path: "Sources/CamBar"
        ),
        .testTarget(
            name: "CamBarTests",
            dependencies: ["CamBarCore"],
            path: "Tests/CamBarTests"
        )
    ]
)
