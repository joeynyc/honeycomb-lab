// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Honeycomb",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "Honeycomb", targets: ["Honeycomb"])
    ],
    targets: [
        .executableTarget(
            name: "Honeycomb",
            path: "Sources/Honeycomb",
            exclude: ["Honeycomb.entitlements"],
            resources: [
                .process("Resources")
            ]
        ),
        .testTarget(
            name: "HoneycombTests",
            dependencies: ["Honeycomb"],
            path: "Tests/HoneycombTests"
        )
    ]
)
