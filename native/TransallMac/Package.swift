// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "TransallMac",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "TransallMac", targets: ["TransallMac"]),
    ],
    targets: [
        .executableTarget(
            name: "TransallMac",
            path: "Sources/TransallMac"
        ),
        .testTarget(
            name: "TransallMacTests",
            dependencies: ["TransallMac"],
            path: "Tests/TransallMacTests"
        ),
    ],
    swiftLanguageModes: [.v5]
)
