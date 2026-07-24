// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "ScrollTwin",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "ScrollTwin", targets: ["ScrollTwin"])
    ],
    targets: [
        .executableTarget(
            name: "ScrollTwin",
            path: "Sources/ScrollTwin"
        ),
        .testTarget(
            name: "ScrollTwinTests",
            dependencies: ["ScrollTwin"],
            path: "Tests/ScrollTwinTests"
        )
    ],
    swiftLanguageModes: [.v5]
)
