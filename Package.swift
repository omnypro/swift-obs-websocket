// swift-tools-version: 5.9
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "swift-obs-websocket",
    platforms: [
        .macOS(.v10_15), .iOS(.v13), .tvOS(.v13)
    ],
    products: [
        .library(
            name: "OBSWebSocket",
            targets: ["OBSWebSocket"]
        ),
    ],
    dependencies: [
      .package(url: "https://github.com/apple/swift-crypto.git", from: "3.1.0"),
    ],
    targets: [
        .target(
            name: "OBSWebSocket",
            dependencies: [
              .product(name: "Crypto", package: "swift-crypto")
            ]
        ),
        .testTarget(
            name: "OBSWebSocketTests",
            dependencies: [
                "OBSWebSocket"
            ]
        ),
    ]
)
