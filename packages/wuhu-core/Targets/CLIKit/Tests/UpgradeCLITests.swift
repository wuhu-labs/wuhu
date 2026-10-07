@testable import CLIKit
import Dependencies
import Fetch
import Foundation
import Scratch
import Synchronization
import Testing

private let archiveBytes = Data("release-archive-payload".utf8)
private let archiveChecksum = SHA256.hex(archiveBytes)
private let platform = ReleasePlatform.current!
private let devAsset = "wuhu-0.1.0-dev.2-\(platform.name).\(platform.archiveExtension)"
private let betaAsset = "wuhu-0.2.0-beta.1-\(platform.name).\(platform.archiveExtension)"

private func index(
  version: String,
  assetName: String,
  lane: String = "dev",
  checksum: String = archiveChecksum,
) -> String {
  """
  {
    "version": "\(version)",
    "lane": "\(lane)",
    "artifacts": {
      "\(platform.name)": {
        "name": "\(assetName)",
        "url": "https://wuhu.ai/releases/\(assetName)",
        "sha256": "\(checksum)"
      }
    }
  }
  """
}

private actor Sink {
  var text = ""

  func append(_ text: String) {
    self.text += text
  }
}

private final class UpgradeHarness: Sendable {
  let scratch: ScratchFolder
  let home: URL
  let stdout: Sink
  let stderr: Sink
  let requests: Mutex<[Request]>

  init() throws {
    self.scratch = try ScratchFolder("upgrade-cli")
    self.home = self.scratch.url
    self.stdout = Sink()
    self.stderr = Sink()
    self.requests = Mutex([])
  }

  var layout: UpgradeLayout {
    UpgradeLayout(root: self.home.appendingPathComponent(".wuhu/bin", isDirectory: true))
  }

  func feed(
    dev: String? = index(version: "0.1.0-dev.2", assetName: devAsset),
    beta: String? = nil,
  ) -> UpgradeEnvironment {
    UpgradeEnvironment(
      fetch: FetchClient { request in
        self.requests.withLock { $0.append(request) }
        switch request.url.absoluteString {
        case "https://wuhu.ai/releases/dev/latest.json":
          guard let dev else { return Response(status: .notFound) }
          return Response(status: .ok, body: .string(dev))
        case "https://wuhu.ai/releases/beta/latest.json":
          guard let beta else { return Response(status: .notFound) }
          return Response(status: .ok, body: .string(beta))
        case "https://wuhu.ai/releases/\(devAsset)", "https://wuhu.ai/releases/\(betaAsset)":
          return Response(status: .ok, body: .bytes(archiveBytes))
        default:
          return Response(status: .notFound)
        }
      },
      extract: { archive, destination in
        let content = try Data(contentsOf: archive)
        try Data("installed:\(SHA256.hex(content))".utf8).write(to: destination.appendingPathComponent("wuhu"))
      },
    )
  }

  func run(
    _ arguments: [String],
    version: String = "0.1.0-dev.1",
    environment: UpgradeEnvironment,
    extraEnvironment: [String: String] = [:],
  ) async -> Int32 {
    let runner = CommandRunner(
      fetch: FetchClient { _ in Response(status: .ok) },
      stdin: { "" },
      stdout: { [stdout] text in await stdout.append(text) },
      stderr: { [stderr] text in await stderr.append(text) },
      environment: ["HOME": self.home.path, "TMPDIR": self.scratch.path].merging(extraEnvironment) { _, new in new },
      currentDirectory: self.home.path,
      version: version,
    )
    return await withDependencies {
      $0[UpgradeEnvironment.self] = environment
    } operation: {
      await runner.run(arguments: arguments)
    }
  }
}

@Suite
struct UpgradeCLITests {
  @Test func hexDigestsStayCanonicalLowercase() {
    #expect(SHA256.hex("abc") == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
  }

  @Test func upgradesToLatestDevAndFlipsAtomically() async throws {
    let harness = try UpgradeHarness()
    let code = await harness.run(["upgrade"], environment: harness.feed())
    let stderr = await harness.stderr.text
    #expect(code == 0, "stderr: \(stderr)")

    let layout = harness.layout
    #expect(layout.currentVersion() == "0.1.0-dev.2")
    let attributes = try FileManager.default.attributesOfItem(atPath: layout.currentBinary.path)
    #expect(attributes[.type] as? FileAttributeType == .typeRegular)
    let installed = try String(contentsOf: layout.currentBinary, encoding: .utf8)
    #expect(installed == "installed:\(archiveChecksum)")
    #expect(await harness.stdout.text == "installed 0.1.0-dev.2 -> \(layout.currentBinary.path)\n")
    #expect(stderr.contains("downloading \(devAsset)\n"))
    #expect(stderr.contains("verified sha256:\(archiveChecksum)\n"))

    let leftovers = try FileManager.default.contentsOfDirectory(atPath: layout.root.path)
      .filter { $0.hasPrefix(".staging") }
    #expect(leftovers.isEmpty)
  }

  // The point of publishing to a public CDN: nothing on the wire carries a
  // credential, and an environment holding none still upgrades.
  @Test func upgradingCarriesNoCredentials() async throws {
    let harness = try UpgradeHarness()
    #expect(await harness.run(["upgrade"], environment: harness.feed()) == 0)
    let requests = harness.requests.withLock { $0 }
    #expect(!requests.isEmpty)
    for request in requests {
      #expect(request.headers.sensitiveValues["authorization"] == nil)
      #expect(request.headers["authorization"] == nil)
      #expect(request.url.host == "wuhu.ai")
    }
  }

  @Test func walletModeInAnExecMayUpgradeButASessionMayOnlyCheck() async throws {
    let inExec = try UpgradeHarness()
    let code = await inExec.run(
      ["upgrade"],
      environment: inExec.feed(),
      extraEnvironment: ["WUHU_EXEC": "1", "WUHU_IDENTITY": "wallet"],
    )
    #expect(code == 0)
    #expect(await inExec.stderr.text.hasPrefix("acting as the local user (wallet)\n"))
    #expect(inExec.layout.currentVersion() == "0.1.0-dev.2")
    #expect(!inExec.requests.withLock { $0 }.isEmpty)

    let session = ["WUHU_EXEC": "1", "WUHU_TOKEN": "exec-token", "WUHU_SPACE_URL": "https://space.test:5530"]
    let checking = try UpgradeHarness()
    let checked = await checking.run(["upgrade", "--check"], environment: checking.feed(), extraEnvironment: session)
    #expect(checked == 0, "a check opens no wallet and installs nothing")

    for arguments in [["upgrade"], ["upgrade", "--rollback"], ["upgrade", "--lane", "beta"]] {
      let installing = try UpgradeHarness()
      let code = await installing.run(arguments, environment: installing.feed(), extraEnvironment: session)
      #expect(code == 1, "\(arguments): on a server's host this swaps the server's binary")
      #expect(await installing.stderr.text == sessionRefusal + "\n")
      #expect(installing.requests.withLock { $0 }.isEmpty)
    }
  }

  @Test func checkPrintsWithoutInstalling() async throws {
    let harness = try UpgradeHarness()
    let code = await harness.run(["upgrade", "--check"], environment: harness.feed())
    #expect(code == 0)
    #expect(await harness.stdout.text == "running 0.1.0-dev.1; latest dev is 0.1.0-dev.2\nrun wuhu upgrade to install\n")
    #expect(!FileManager.default.fileExists(atPath: harness.layout.root.path))
  }

  @Test func upToDateWhenOwnVersionIsLatest() async throws {
    let harness = try UpgradeHarness()
    let environment = harness.feed()
    #expect(await harness.run(["upgrade"], version: "0.1.0-dev.2", environment: environment) == 0)
    #expect(await harness.stdout.text == "up to date: 0.1.0-dev.2 is the latest dev release\n")

    _ = await harness.run(["upgrade", "--check"], version: "0.1.0-dev.2-4-gabc1234-dirty", environment: environment)
    #expect(await harness.stdout.text.hasSuffix("running 0.1.0-dev.2-4-gabc1234-dirty; latest dev is 0.1.0-dev.2\nup to date\n"))
  }

  @Test func laneCrossingNeedsExplicitLane() async throws {
    let harness = try UpgradeHarness()
    let beta = index(version: "0.2.0-beta.1", assetName: betaAsset, lane: "beta")
    let environment = harness.feed(beta: beta)
    let code = await harness.run(["upgrade", "--lane", "beta"], version: "0.3.0-dev.9", environment: environment)
    let stderr = await harness.stderr.text
    #expect(code == 0, "stderr: \(stderr)")
    #expect(harness.layout.currentVersion() == "0.2.0-beta.1")
  }

  @Test func anEmptyLaneTeachesRatherThanCrashes() async throws {
    let harness = try UpgradeHarness()
    let code = await harness.run(["upgrade", "--lane", "release"], environment: harness.feed())
    #expect(code == 1)
    #expect(await harness.stderr.text.contains("no published releases in the release lane yet"))
  }

  @Test func unstampedBinaryTeachesLaneFlag() async throws {
    let harness = try UpgradeHarness()
    let code = await harness.run(["upgrade"], version: "0.0.0-unstamped", environment: harness.feed())
    #expect(code == 1)
    #expect(await harness.stderr.text.contains("wuhu upgrade --lane dev|beta|release"))
  }

  @Test func checksumMismatchAbortsWithoutInstalling() async throws {
    let harness = try UpgradeHarness()
    let bogus = String(repeating: "0", count: 64)
    let feed = index(version: "0.1.0-dev.2", assetName: devAsset, checksum: bogus)
    let code = await harness.run(["upgrade"], environment: harness.feed(dev: feed))
    #expect(code == 1)
    #expect(await harness.stderr.text.contains("checksum mismatch for \(devAsset)"))
    #expect(harness.layout.currentVersion() == nil)
    #expect(!harness.layout.versionDirectoryExists("0.1.0-dev.2"))
  }

  // The artifact name is what the install is recorded under, so a pointer whose
  // name disagrees with its version is refused rather than trusted.
  @Test func aPointerNamingAnotherAssetIsRefused() async throws {
    let harness = try UpgradeHarness()
    let feed = index(version: "0.1.0-dev.2", assetName: "wuhu-9.9.9-other.zip")
    let code = await harness.run(["upgrade"], environment: harness.feed(dev: feed))
    #expect(code == 1)
    #expect(await harness.stderr.text.contains("names wuhu-9.9.9-other.zip, not \(devAsset); refusing"))
    #expect(harness.layout.currentVersion() == nil)
  }

  @Test func aPointerMissingThisPlatformIsRefused() async throws {
    let harness = try UpgradeHarness()
    let feed = """
    {"version": "0.1.0-dev.2", "lane": "dev", "artifacts": {}}
    """
    let code = await harness.run(["upgrade"], environment: harness.feed(dev: feed))
    #expect(code == 1)
    #expect(await harness.stderr.text.contains("has no \(platform.name) artifact"))
    #expect(!harness.layout.versionDirectoryExists("0.1.0-dev.2"))
  }

  // A lane key holding another lane's version means the publisher wrote the
  // wrong object; installing it would move the caller between lanes silently.
  @Test func aPointerFromAnotherLaneIsRefused() async throws {
    let harness = try UpgradeHarness()
    let feed = index(version: "0.2.0-beta.1", assetName: betaAsset)
    let code = await harness.run(["upgrade"], environment: harness.feed(dev: feed))
    #expect(code == 1)
    #expect(await harness.stderr.text.contains("which is not a dev release"))
    #expect(harness.layout.currentVersion() == nil)
  }

  @Test func rollbackFlipsBack() async throws {
    let harness = try UpgradeHarness()
    let environment = harness.feed()
    let layout = harness.layout
    try FileManager.default.createDirectory(at: layout.root, withIntermediateDirectories: true)
    let payload = try layout.stagingDirectory()
    try Data("old".utf8).write(to: payload.appendingPathComponent("wuhu"))
    try layout.install(payload: payload, version: "0.1.0-dev.1")
    try layout.flip(to: "0.1.0-dev.1")

    #expect(await harness.run(["upgrade"], environment: environment) == 0)
    #expect(layout.currentVersion() == "0.1.0-dev.2")
    #expect(layout.previousVersion() == "0.1.0-dev.1")

    #expect(await harness.run(["upgrade", "--rollback"], environment: environment) == 0)
    #expect(layout.currentVersion() == "0.1.0-dev.1")
    #expect(try String(contentsOf: layout.currentBinary, encoding: .utf8) == "old")
    #expect(await harness.stdout.text.contains("rolled back \(layout.currentBinary.path): 0.1.0-dev.2 -> 0.1.0-dev.1"))
  }

  @Test func alreadyFlippedLayoutSuggestsFreshShell() async throws {
    let harness = try UpgradeHarness()
    let environment = harness.feed()
    #expect(await harness.run(["upgrade"], environment: environment) == 0)
    #expect(await harness.run(["upgrade"], environment: environment) == 0)
    #expect(await harness.stdout.text.contains("is already 0.1.0-dev.2"))
  }

  @Test func aHandDowngradeUpgradesAgainWithoutDownloading() async throws {
    let harness = try UpgradeHarness()
    let environment = harness.feed()
    let layout = harness.layout
    try FileManager.default.createDirectory(at: layout.root, withIntermediateDirectories: true)
    let payload = try layout.stagingDirectory()
    try Data("old".utf8).write(to: payload.appendingPathComponent("wuhu"))
    try layout.install(payload: payload, version: "0.1.0-dev.1")
    try layout.flip(to: "0.1.0-dev.1")
    #expect(await harness.run(["upgrade"], environment: environment) == 0)

    try FileManager.default.removeItem(at: layout.currentBinary)
    try FileManager.default.copyItem(at: layout.root.appendingPathComponent("0.1.0-dev.1/wuhu"), to: layout.currentBinary)
    #expect(layout.currentVersion() == "0.1.0-dev.2", "a hand downgrade leaves .current behind")
    harness.requests.withLock { $0.removeAll() }

    #expect(await harness.run(["upgrade"], environment: environment) == 0)
    #expect(try String(contentsOf: layout.currentBinary, encoding: .utf8) == "installed:\(archiveChecksum)")
    #expect(await harness.stdout.text.hasSuffix("installed 0.1.0-dev.2 -> \(layout.currentBinary.path)\n"))
    let fetched = harness.requests.withLock { $0.map(\.url.absoluteString) }
    #expect(fetched == ["https://wuhu.ai/releases/dev/latest.json"])
  }

  @Test func decoyOnPathTriggersShadowWarning() async throws {
    let harness = try UpgradeHarness()
    let decoyDirectory = harness.home.appendingPathComponent("decoy", isDirectory: true)
    try FileManager.default.createDirectory(at: decoyDirectory, withIntermediateDirectories: true)
    let decoy = decoyDirectory.appendingPathComponent("wuhu")
    try Data("#!/bin/sh\n".utf8).write(to: decoy)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: decoy.path)

    let code = await harness.run(
      ["upgrade"],
      environment: harness.feed(),
      extraEnvironment: ["PATH": "\(decoyDirectory.path):\(harness.layout.root.path)"],
    )
    #expect(code == 0)
    #expect(await harness.stderr.text.contains("warning: \(decoy.path) shadows \(harness.layout.currentBinary.path) on PATH"))
  }
}
