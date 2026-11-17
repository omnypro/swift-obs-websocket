// swift-tools-version: 6.0

import PackageDescription

// 14 and 17 are the first releases with Observation, which the WebSocket
// classes use so SwiftUI can follow their state.
let package = Package(
  name: "swift-obs-websocket",
  platforms: [
    .macOS(.v14), .iOS(.v17), .tvOS(.v17),
  ],
  products: [
    .library(
      name: "OBSWebSocket",
      targets: ["OBSWebSocket"]
    )
  ],
  targets: [
    .target(name: "OBSWebSocket"),
    .testTarget(
      name: "OBSWebSocketTests",
      dependencies: [
        "OBSWebSocket"
      ]
    ),
  ]
)
