// swift-tools-version: 6.2
import PackageDescription

let strictConcurrency: [SwiftSetting] = [
  .unsafeFlags([
    "-Xfrontend",
    "-strict-concurrency=complete",
    "-Xfrontend",
    "-warn-concurrency",
  ]),
]

let package = Package(
  name: "wuhu",
  platforms: [
    .macOS(.v14),
  ],
  products: [
    .library(name: "PiAI", targets: ["PiAI"]),
    .executable(name: "wuhu", targets: ["wuhu"]),
  ],
  dependencies: [
    .package(url: "https://github.com/nicklockwood/SwiftFormat.git", from: "0.59.1"),
    .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.0"),
    .package(url: "https://github.com/swiftlang/swift-testing.git", from: "6.2.0"),
    .package(url: "https://github.com/swift-server/async-http-client.git", from: "1.27.0"),
  ],
  targets: [
    .target(
      name: "PiAI",
      dependencies: [
        .product(name: "AsyncHTTPClient", package: "async-http-client"),
      ],
      swiftSettings: strictConcurrency,
    ),
    .executableTarget(
      name: "wuhu",
      dependencies: [
        "PiAI",
        .product(name: "ArgumentParser", package: "swift-argument-parser"),
      ],
      swiftSettings: strictConcurrency,
    ),
    .testTarget(
      name: "PiAITests",
      dependencies: [
        "PiAI",
        .product(name: "Testing", package: "swift-testing"),
      ],
      swiftSettings: strictConcurrency,
    ),
  ],
)
