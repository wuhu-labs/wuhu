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

let grdbDependency: Package.Dependency = .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.10.0")

let package = Package(
  name: "wuhu",
  platforms: [
    .macOS(.v14),
    .iOS(.v16),
  ],
  products: [
    .library(name: "WuhuAPI", targets: ["WuhuAPI"]),
    .library(name: "WuhuCLIKit", targets: ["WuhuCLIKit"]),
    .library(name: "WuhuCoreClient", targets: ["WuhuCoreClient"]),
    .library(name: "WuhuCore", targets: ["WuhuCore"]),
    .library(name: "WuhuClient", targets: ["WuhuClient"]),
    .library(name: "WuhuServer", targets: ["WuhuServer"]),
    .library(name: "WuhuRunner", targets: ["WuhuRunner"]),
    .executable(name: "wuhu", targets: ["wuhu"]),
    .executable(name: "wuhu-bench-find", targets: ["WuhuBenchFind"]),
  ],
  dependencies: [
    .package(url: "https://github.com/wuhu-labs/wuhu-ai.git", from: "0.1.0"),
    .package(url: "https://github.com/wuhu-labs/wuhu-workspace-engine.git", from: "0.1.0"),
    .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.0"),
    .package(url: "https://github.com/swiftlang/swift-testing.git", revision: "48a471ab313e858258ab0b9b0bf2cea55a50cefb"),
    .package(url: "https://github.com/hummingbird-project/hummingbird.git", from: "2.0.0"),
    .package(url: "https://github.com/hummingbird-project/hummingbird-websocket.git", from: "2.0.0"),
    .package(url: "https://github.com/jpsim/Yams.git", from: "5.0.0"),
    grdbDependency,
  ],
  targets: [
    .target(
      name: "WuhuAPI",
      dependencies: [
        .product(name: "PiAI", package: "wuhu-ai"),
      ],
      swiftSettings: strictConcurrency,
    ),
    .target(
      name: "WuhuCLIKit",
      dependencies: [
        .product(name: "PiAI", package: "wuhu-ai"),
        "WuhuAPI",
        .product(name: "ArgumentParser", package: "swift-argument-parser"),
      ],
      swiftSettings: strictConcurrency,
    ),
    .target(
      name: "WuhuCoreClient",
      dependencies: [
        "WuhuAPI",
        .product(name: "PiAI", package: "wuhu-ai"),
      ],
      swiftSettings: strictConcurrency,
    ),
    .target(
      name: "WuhuCore",
      dependencies: [
        "WuhuCoreClient",
        "WuhuAPI",
        .product(name: "PiAI", package: "wuhu-ai"),
        .product(name: "GRDB", package: "GRDB.swift"),
      ],
      swiftSettings: strictConcurrency,
    ),
    .target(
      name: "WuhuClient",
      dependencies: [
        "WuhuAPI",
        "WuhuCoreClient",
      ],
      swiftSettings: strictConcurrency,
    ),
    .target(
      name: "WuhuServer",
      dependencies: [
        "WuhuCore",
        .product(name: "Hummingbird", package: "hummingbird"),
        .product(name: "HummingbirdWebSocket", package: "hummingbird-websocket"),
        .product(name: "HummingbirdWSClient", package: "hummingbird-websocket"),
        .product(name: "Yams", package: "Yams"),
        .product(name: "WorkspaceEngine", package: "wuhu-workspace-engine"),
        .product(name: "WorkspaceScanner", package: "wuhu-workspace-engine"),
      ],
      swiftSettings: strictConcurrency,
    ),
    .target(
      name: "WuhuRunner",
      dependencies: [
        "WuhuCore",
        .product(name: "Hummingbird", package: "hummingbird"),
        .product(name: "HummingbirdWebSocket", package: "hummingbird-websocket"),
        .product(name: "HummingbirdWSClient", package: "hummingbird-websocket"),
        .product(name: "Yams", package: "Yams"),
      ],
      swiftSettings: strictConcurrency,
    ),
    .executableTarget(
      name: "wuhu",
      dependencies: [
        "WuhuClient",
        "WuhuCLIKit",
        "WuhuServer",
        "WuhuRunner",
        .product(name: "ArgumentParser", package: "swift-argument-parser"),
        .product(name: "Yams", package: "Yams"),
      ],
      swiftSettings: strictConcurrency,
    ),
    .executableTarget(
      name: "WuhuBenchFind",
      dependencies: [
        "WuhuCore",
        .product(name: "PiAI", package: "wuhu-ai"),
      ],
      swiftSettings: strictConcurrency,
    ),
    .testTarget(
      name: "WuhuCoreTests",
      dependencies: [
        "WuhuCore",
        "WuhuCoreClient",
        .product(name: "Testing", package: "swift-testing"),
      ],
      swiftSettings: strictConcurrency,
    ),
    .testTarget(
      name: "WuhuClientTests",
      dependencies: [
        "WuhuClient",
        .product(name: "Testing", package: "swift-testing"),
      ],
      swiftSettings: strictConcurrency,
    ),
    .testTarget(
      name: "WuhuServerTests",
      dependencies: [
        "WuhuServer",
        .product(name: "Testing", package: "swift-testing"),
      ],
      swiftSettings: strictConcurrency,
    ),
    .testTarget(
      name: "WuhuCLITests",
      dependencies: [
        "wuhu",
        .product(name: "Testing", package: "swift-testing"),
      ],
      swiftSettings: strictConcurrency,
    ),
    .testTarget(
      name: "WuhuAPITests",
      dependencies: [
        "WuhuAPI",
        .product(name: "Testing", package: "swift-testing"),
      ],
      swiftSettings: strictConcurrency,
    ),
  ],
)
