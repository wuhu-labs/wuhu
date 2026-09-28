@testable import CLIKit
import Foundation
import Scratch
import Testing

@Suite
struct UpgradeParsingTests {
  @Test func parsesBareUpgrade() throws {
    #expect(try Command.parse(["upgrade"]) == .upgrade(UpgradeCommand(check: false, rollback: false, lane: nil)))
  }

  @Test func parsesFlags() throws {
    #expect(
      try Command.parse(["upgrade", "--check", "--lane", "beta"])
        == .upgrade(UpgradeCommand(check: true, rollback: false, lane: .beta)),
    )
    #expect(
      try Command.parse(["upgrade", "--rollback"])
        == .upgrade(UpgradeCommand(check: false, rollback: true, lane: nil)),
    )
  }

  @Test(arguments: [
    ["upgrade", "now"],
    ["upgrade", "--lane"],
    ["upgrade", "--lane", "nightly"],
    ["upgrade", "--rollback", "--check"],
    ["upgrade", "--rollback", "--lane", "dev"],
  ])
  func usageErrors(_ arguments: [String]) {
    #expect(throws: UsageError.self) {
      try Command.parse(arguments)
    }
  }
}

@Suite
struct ReleaseVersionTests {
  @Test func parsesEveryLane() {
    #expect(ReleaseVersion.parse("0.1.0") == ReleaseVersion(major: 0, minor: 1, patch: 0, lane: .release, iteration: 0))
    #expect(ReleaseVersion.parse("1.2.3-dev.7") == ReleaseVersion(major: 1, minor: 2, patch: 3, lane: .dev, iteration: 7))
    #expect(ReleaseVersion.parse("0.2.0-beta.12") == ReleaseVersion(major: 0, minor: 2, patch: 0, lane: .beta, iteration: 12))
  }

  @Test(arguments: ["0.1", "0.1.0.0", "0.1.0-rc.1", "0.1.0-dev", "0.1.0-dev.x", "0.1.0-release.1", "v0.1.0", "0.1.0-dev.1.2", "0.-1.0-dev.1", "0.1.0-dev.+3", ""])
  func rejectsForeignGrammar(_ text: String) {
    #expect(ReleaseVersion.parse(text) == nil)
  }

  @Test func parsesTags() {
    #expect(ReleaseVersion.parse(tag: "wuhu/v0.1.0-dev.2")?.description == "0.1.0-dev.2")
    #expect(ReleaseVersion.parse(tag: "wuhu/v0.1.0")?.lane == .release)
    #expect(ReleaseVersion.parse(tag: "v0.1.0") == nil)
    #expect(ReleaseVersion.parse(tag: "app/v1.0.0-31") == nil)
  }

  @Test func parsesStampedVersions() {
    #expect(ReleaseVersion.parseStamped("0.1.0-dev.1")?.description == "0.1.0-dev.1")
    #expect(ReleaseVersion.parseStamped("0.1.0-dev.1-dirty")?.description == "0.1.0-dev.1")
    #expect(ReleaseVersion.parseStamped("0.1.0-dev.1-5-g1a2b3c4d5")?.description == "0.1.0-dev.1")
    #expect(ReleaseVersion.parseStamped("0.2.0-beta.3-12-gabcdef123-dirty")?.description == "0.2.0-beta.3")
    #expect(ReleaseVersion.parseStamped("1.0.0-4-gdeadbeef1")?.description == "1.0.0")
    #expect(ReleaseVersion.parseStamped("0.0.0-unstamped") == nil)
    #expect(ReleaseVersion.parseStamped("0.0.0-untagged") == nil)
    #expect(ReleaseVersion.parseStamped("0.1.0-dev.1-5-gnothex") == nil)
  }

  @Test func ordersWithinLaneByTrainThenIteration() throws {
    let versions = ["0.9.9-dev.30", "1.0.0-dev.2", "1.0.0-dev.11", "2.0.0-beta.1", "3.0.0"]
      .map { ReleaseVersion.parse($0)! }
    #expect(ReleaseVersion.newest(in: .dev, of: versions)?.description == "1.0.0-dev.11")
    #expect(ReleaseVersion.newest(in: .beta, of: versions)?.description == "2.0.0-beta.1")
    #expect(ReleaseVersion.newest(in: .release, of: versions)?.description == "3.0.0")
    #expect(ReleaseVersion.newest(in: .dev, of: [ReleaseVersion.parse("1.0.0")!]) == nil)
  }
}

@Suite
struct UpgradeLayoutTests {
  private func layout(in scratch: ScratchFolder) throws -> UpgradeLayout {
    let root = scratch.url.appendingPathComponent("bin", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return UpgradeLayout(root: root)
  }

  private func plantVersion(_ layout: UpgradeLayout, _ version: String, content: String = "binary") throws {
    let payload = try layout.stagingDirectory()
    try Data(content.utf8).write(to: payload.appendingPathComponent("wuhu"))
    try layout.install(payload: payload, version: version)
  }

  @Test func locateUsesWuhuConfigDirectory() throws {
    let layout = try UpgradeLayout.locate(environment: ["HOME": "/Users/someone"])
    #expect(layout.root.path == "/Users/someone/.wuhu/bin")
    #expect(throws: (any Error).self) {
      try UpgradeLayout.locate(environment: [:])
    }
  }

  @Test func currentVersionRejectsForeignSymlinkTargets() throws {
    let scratch = try ScratchFolder("upgrade")
    defer { scratch.remove() }
    let layout = try self.layout(in: scratch)
    try FileManager.default.createSymbolicLink(atPath: layout.currentLink.path, withDestinationPath: "/opt/wuhu/wuhu")
    #expect(layout.currentVersion() == nil)
  }

  @Test func lockIsExclusive() throws {
    let scratch = try ScratchFolder("upgrade")
    defer { scratch.remove() }
    let layout = try self.layout(in: scratch)
    let lock = try layout.acquireLock()
    #expect(throws: CLIError.self) { try layout.acquireLock() }
    try FileManager.default.removeItem(at: lock)
    _ = try layout.acquireLock()
  }

  @Test func flipPointsCurrentAndRecordsPrevious() throws {
    let scratch = try ScratchFolder("upgrade")
    defer { scratch.remove() }
    let layout = try self.layout(in: scratch)
    try self.plantVersion(layout, "0.1.0-dev.1", content: "one")
    try self.plantVersion(layout, "0.1.0-dev.2", content: "two")
    #expect(layout.currentVersion() == nil)

    try layout.flip(to: "0.1.0-dev.1")
    #expect(layout.currentVersion() == "0.1.0-dev.1")
    #expect(layout.previousVersion() == nil)

    try layout.flip(to: "0.1.0-dev.2")
    #expect(layout.currentVersion() == "0.1.0-dev.2")
    #expect(layout.previousVersion() == "0.1.0-dev.1")
    let resolved = try String(contentsOf: layout.currentLink.resolvingSymlinksInPath(), encoding: .utf8)
    #expect(resolved == "two")
  }

  @Test func rollbackTogglesBetweenLastTwoVersions() throws {
    let scratch = try ScratchFolder("upgrade")
    defer { scratch.remove() }
    let layout = try self.layout(in: scratch)
    try self.plantVersion(layout, "0.1.0-dev.1")
    try self.plantVersion(layout, "0.1.0-dev.2")
    try layout.flip(to: "0.1.0-dev.1")
    try layout.flip(to: "0.1.0-dev.2")

    let back = try layout.rollback()
    #expect(back == (from: "0.1.0-dev.2", to: "0.1.0-dev.1"))
    #expect(layout.currentVersion() == "0.1.0-dev.1")

    let forward = try layout.rollback()
    #expect(forward == (from: "0.1.0-dev.1", to: "0.1.0-dev.2"))
    #expect(layout.currentVersion() == "0.1.0-dev.2")
  }

  @Test func rollbackWithoutHistoryFails() throws {
    let scratch = try ScratchFolder("upgrade")
    defer { scratch.remove() }
    let layout = try self.layout(in: scratch)
    #expect(throws: CLIError.self) { try layout.rollback() }
    try self.plantVersion(layout, "0.1.0-dev.1")
    try layout.flip(to: "0.1.0-dev.1")
    #expect(throws: CLIError.self) { try layout.rollback() }
  }

  @Test func installRefusesPayloadWithoutBinaryAndCurrentReplacement() throws {
    let scratch = try ScratchFolder("upgrade")
    defer { scratch.remove() }
    let layout = try self.layout(in: scratch)
    let empty = try layout.stagingDirectory()
    #expect(throws: CLIError.self) {
      try layout.install(payload: empty, version: "0.1.0-dev.1")
    }
    try self.plantVersion(layout, "0.1.0-dev.1")
    try layout.flip(to: "0.1.0-dev.1")
    let replacement = try layout.stagingDirectory()
    try Data("other".utf8).write(to: replacement.appendingPathComponent("wuhu"))
    #expect(throws: CLIError.self) {
      try layout.install(payload: replacement, version: "0.1.0-dev.1")
    }
  }

  @Test func pruneKeepsLastThreeAndProtectsCurrentAndPrevious() throws {
    let scratch = try ScratchFolder("upgrade")
    defer { scratch.remove() }
    let layout = try self.layout(in: scratch)
    let stamp = Date(timeIntervalSince1970: 1_700_000_000)
    for (index, version) in ["0.1.0-dev.1", "0.1.0-dev.2", "0.1.0-dev.3", "0.1.0-dev.4", "0.1.0-dev.5"].enumerated() {
      try self.plantVersion(layout, version)
      try FileManager.default.setAttributes(
        [.modificationDate: stamp.addingTimeInterval(Double(index) * 60)],
        ofItemAtPath: layout.root.appendingPathComponent(version).path,
      )
    }
    try layout.flip(to: "0.1.0-dev.4")
    try layout.flip(to: "0.1.0-dev.5")

    let removed = try layout.prune(keep: 3)
    #expect(Set(removed) == Set(["0.1.0-dev.1", "0.1.0-dev.2"]))
    #expect(layout.versionDirectoryExists("0.1.0-dev.3"))
    #expect(layout.currentVersion() == "0.1.0-dev.5")
    #expect(layout.previousVersion() == "0.1.0-dev.4")
  }

  @Test func shadowWarningNamesTheDecoy() throws {
    let layout = UpgradeLayout(root: URL(fileURLWithPath: "/home/dev/.wuhu/bin", isDirectory: true))
    let executables: Set<String> = ["/decoy/wuhu", "/home/dev/.wuhu/bin/wuhu"]
    let warning = shadowWarning(
      path: "/decoy:/home/dev/.wuhu/bin",
      layout: layout,
      isExecutable: executables.contains,
      resolve: { $0 },
    )
    #expect(warning == "warning: /decoy/wuhu shadows /home/dev/.wuhu/bin/wuhu on PATH; remove it or reorder PATH\n")

    #expect(shadowWarning(
      path: "/home/dev/.wuhu/bin:/decoy",
      layout: layout,
      isExecutable: executables.contains,
      resolve: { $0 },
    ) == nil)

    #expect(shadowWarning(
      path: "/elsewhere",
      layout: layout,
      isExecutable: executables.contains,
      resolve: { $0 },
    ) == "warning: /home/dev/.wuhu/bin is not on PATH; the installed wuhu will not be found\n")

    #expect(shadowWarning(
      path: "/links",
      layout: layout,
      isExecutable: { $0 == "/links/wuhu" },
      resolve: { $0 == "/links/wuhu" ? "/home/dev/.wuhu/bin/wuhu" : $0 },
    ) == nil)
  }
}
