// swift-tools-version: 6.0

import PackageDescription
import Foundation

let pdfiumLibrary = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .appendingPathComponent("ThirdParty/PDFium/lib").path

let package = Package(
    name: "TransallMac",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "TransallMac", targets: ["TransallMac"]),
    ],
    targets: [
        .systemLibrary(name: "CPDFium", path: "Sources/CPDFium"),
        .executableTarget(
            name: "TransallMac",
            dependencies: ["CPDFium"],
            path: "Sources/TransallMac",
            linkerSettings: [.unsafeFlags(["-L", pdfiumLibrary, "-lc++"])]
        ),
        .testTarget(
            name: "TransallMacTests",
            dependencies: ["TransallMac"],
            path: "Tests/TransallMacTests"
        ),
    ],
    swiftLanguageModes: [.v5]
)
