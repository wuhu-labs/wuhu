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

#if os(Linux)
  let grdbDependency: Package.Dependency = .package(url: "https://github.com/groue/GRDB.swift.git", branch: "development")
#else
  let grdbDependency: Package.Dependency = .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.9.0")
#endif

let package = Package(
  name: "wuhu",
  platforms: [
    .macOS(.v14),
  ],
  products: [
    .library(name: "PiAI", targets: ["PiAI"]),
    .library(name: "PiAgent", targets: ["PiAgent"]),
    .library(name: "WuhuAPI", targets: ["WuhuAPI"]),
    .library(name: "WuhuCore", targets: ["WuhuCore"]),
    .library(name: "WuhuClient", targets: ["WuhuClient"]),
    .library(name: "WuhuServer", targets: ["WuhuServer"]),
    .executable(name: "wuhu", targets: ["wuhu"]),
  ],
  dependencies: [
    .package(url: "https://github.com/nicklockwood/SwiftFormat.git", from: "0.59.1"),
    .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.0"),
    .package(url: "https://github.com/swiftlang/swift-testing.git", from: "6.2.0"),
    .package(url: "https://github.com/swift-server/async-http-client.git", from: "1.27.0"),
    .package(url: "https://github.com/hummingbird-project/hummingbird.git", from: "2.0.0"),
    .package(url: "https://github.com/jpsim/Yams.git", from: "5.0.0"),
    grdbDependency,
  ],
  targets: [
    .target(
      name: "PiAI",
      dependencies: [
        .product(name: "AsyncHTTPClient", package: "async-http-client"),
      ],
      swiftSettings: strictConcurrency,
    ),
    .target(
      name: "PiAgent",
      dependencies: [
        "PiAI",
      ],
      swiftSettings: strictConcurrency,
    ),
    .target(
      name: "WuhuAPI",
      dependencies: [
        "PiAI",
      ],
      swiftSettings: strictConcurrency,
    ),
    .target(
      name: "WuhuCore",
      dependencies: [
        "WuhuAPI",
        "PiAI",
        "PiAgent",
        .product(name: "GRDB", package: "GRDB.swift"),
      ],
      swiftSettings: strictConcurrency,
    ),
    .target(
      name: "WuhuClient",
      dependencies: [
        "WuhuAPI",
      ],
      swiftSettings: strictConcurrency,
    ),
    .target(
      name: "WuhuServer",
      dependencies: [
        "WuhuCore",
        .product(name: "Hummingbird", package: "hummingbird"),
        .product(name: "Yams", package: "Yams"),
      ],
      swiftSettings: strictConcurrency,
    ),
    .executableTarget(
      name: "wuhu",
      dependencies: [
        "WuhuClient",
        "WuhuServer",
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
    .testTarget(
      name: "PiAgentTests",
      dependencies: [
        "PiAgent",
        .product(name: "Testing", package: "swift-testing"),
      ],
      swiftSettings: strictConcurrency,
    ),
    .testTarget(
      name: "WuhuCoreTests",
      dependencies: [
        "WuhuCore",
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
  ],
)
