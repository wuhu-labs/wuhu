import DeterministicDependencies
#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
@testable import CLIKit
#if os(Linux)
  import Glibc
#else
  import Darwin
#endif
import Clocks
import Dependencies
import Fetch
import struct MachineContract.MachineV2Artifact
import struct MachineContract.MachineV2Upgrade
import struct OperationProtocol.MachineDescription
import struct OperationProtocol.MachineUpgradeReport
import struct OperationProtocol.OperationLimits
import Scratch
import Synchronization
import Testing

@Suite(.deterministicDependencies) struct MachineV2AutoUpgradeTests {
  /// Archives hold their version string; extraction writes it as `wuhu`, whose `--version` prints it back.
  final class Box: Sendable {
    let announcement: Mutex<MachineV2Upgrade>
    let downloads = Mutex<[URL]>([])
    let archives = Mutex<[URL]>([])
    let launches = Mutex<[[String]]>([])
    let commands = Mutex<[[String]]>([])
    let restarts = Mutex(0)
    let healthy = Mutex(false)
    let launchFails = Mutex(false)
    let home: MachineV2Home
    let installer: MachineV2Installer
    let scratch: ScratchFolder

    init(_ announcement: MachineV2Upgrade) throws {
      scratch = try ScratchFolder("machine-v2-auto-upgrade")
      try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: scratch.path)
      let resolved = try #require(realpath(scratch.path, nil))
      defer { free(resolved) }
      let root = URL(fileURLWithPath: String(cString: resolved))
      home = MachineV2Home(root: root.appendingPathComponent(".wuhu/machine-v2"), machine: "mc_test-v2")
      self.announcement = Mutex(announcement)
      installer = MachineV2Installer(home: root, machine: "mc_test-v2", platform: .linux, userID: 501, command: { _ in "" })
      try home.prepare()
      try FileManager.default.createDirectory(at: installer.serviceFile.deletingLastPathComponent(), withIntermediateDirectories: true)
      try Data("installed unit".utf8).write(to: installer.serviceFile)
      try Self.executable("0.1.0", at: home.binary)
    }

    static func executable(_ text: String, at path: URL) throws {
      try Data(text.utf8).write(to: path)
      try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: path.path)
    }

    var serviceInstaller: MachineV2Installer {
      MachineV2Installer(home: installer.home, machine: installer.machine, platform: .linux, userID: 501, command: { arguments in
        self.commands.withLock { $0.append(arguments) }
        if arguments.contains("restart"), self.healthy.withLock({ $0 }) {
          var state = self.home.loadUpgradeState()
          state.trial?.healthyAt = 1
          try self.home.saveUpgradeState(state)
        }
        if arguments == ["/usr/bin/id", "-un"] { return "agent\n" }
        if arguments.first == "/usr/bin/loginctl" { return "yes\n" }
        return ""
      })
    }

    func upgrader(running: String = "0.1.0", platform: String? = "linux-amd64", signature: @escaping @Sendable (URL) throws -> Void = { _ in }, now: Date = Date()) -> MachineV2AutoUpgrader {
      MachineV2AutoUpgrader(home: home, version: running, platform: platform, environment: .init(
        announce: { self.announcement.withLock { $0 } },
        download: { url in
          self.downloads.withLock { $0.append(url) }
          return Data(url.deletingPathExtension().deletingPathExtension().lastPathComponent.utf8)
        },
        extract: { archive, payload in
          self.archives.withLock { $0.append(archive) }
          try Self.executable(String(decoding: try Data(contentsOf: archive), as: UTF8.self), at: payload.appendingPathComponent("wuhu"))
        },
        command: { arguments in "wuhu \(String(decoding: try Data(contentsOf: URL(fileURLWithPath: arguments[0])), as: UTF8.self)) (0123456789abcdef0123456789abcdef01234567, 2026-10-15)\n" },
        verifySignature: { candidate, _ in try signature(candidate) },
        launch: { arguments in
          if self.launchFails.withLock({ $0 }) { throw MachineV2RuntimeError(.invalidConfiguration, message: "spawn") }
          self.launches.withLock { $0.append(arguments) }
          return 42
        },
        reaped: { _ in true },
        now: { now },
      ))
    }

    func apply(_ launch: [String], installer: MachineV2Installer? = nil, now: @escaping @Sendable () -> Date = { Date() }) async {
      await MachineV2AutoUpgrade.apply(home: home, candidate: URL(fileURLWithPath: launch[4]), target: launch[5], running: "0.1.0", token: launch[6], installer: installer ?? serviceInstaller, now: now)
    }

    var state: MachineV2UpgradeState { home.loadUpgradeState() }
    var binary: String { (try? String(contentsOf: home.binary, encoding: .utf8)) ?? "" }
  }

  static func ready(_ version: String, pinned: Bool = false, sha: String? = nil) -> MachineV2Upgrade {
    MachineV2Upgrade(version: version, pinned: pinned, status: .ready, artifacts: [
      MachineV2Artifact(platform: "linux-amd64", url: "https://wuhu.ai/releases/\(version).tar.gz", sha256: sha ?? SHA256.hex(version)),
      MachineV2Artifact(platform: "macos-arm64", url: "https://wuhu.ai/releases/\(version).zip", sha256: sha ?? SHA256.hex(version)),
    ])
  }

  @Test func equalVersionDoesNothing() async throws {
    let box = try Box(Self.ready("0.1.0"))
    defer { box.scratch.remove() }
    await box.upgrader().check()
    #expect(box.downloads.withLock { $0 }.isEmpty)
    #expect(box.launches.withLock { $0 }.isEmpty)
    #expect(!FileManager.default.fileExists(atPath: box.home.upgradeStateFile.path))
  }

  @Test(arguments: [
    MachineV2Upgrade(version: "0.2.0", pinned: false, status: .paused, artifacts: []),
    MachineV2Upgrade(version: nil, pinned: false, status: .paused, artifacts: []),
    MachineV2Upgrade(version: "0.2.0", pinned: false, status: .unpublished, artifacts: []),
    MachineV2Upgrade(version: "0.2.0", pinned: false, status: .unreachable, artifacts: []),
    MachineV2Upgrade(version: nil, pinned: false, status: .unstamped, artifacts: []),
    MachineV2AutoUpgradeTests.ready("0.1.0", pinned: true),
  ])
  func heldOrPinnedTargetsTakeNoAction(_ announcement: MachineV2Upgrade) async throws {
    let box = try Box(announcement)
    defer { box.scratch.remove() }
    await box.upgrader().check()
    #expect(box.downloads.withLock { $0 }.isEmpty)
    #expect(box.launches.withLock { $0 }.isEmpty)
    #expect(box.binary == "0.1.0")
  }

  @Test func readyTargetHandsAVerifiedCandidateToTheDetachedHelper() async throws {
    let box = try Box(Self.ready("0.2.0", pinned: true))
    defer { box.scratch.remove() }
    await box.upgrader(platform: "linux-arm64").check()
    #expect(box.downloads.withLock { $0 }.isEmpty)
    await box.upgrader().check()
    #expect(box.downloads.withLock { $0 } == [URL(string: "https://wuhu.ai/releases/0.2.0.tar.gz")!])
    let launch = try #require(box.launches.withLock { $0 }.first)
    #expect(Array(launch.prefix(4)) == [box.home.binary.path, "machine-v2", "apply-upgrade", "mc_test-v2"])
    #expect(launch.count == 7)
    #expect(launch[5] == "0.2.0")
    #expect(box.state.trial?.version == "0.2.0")
    #expect(box.state.trial?.owner == launch[6])
    #expect(try String(contentsOf: URL(fileURLWithPath: launch[4]), encoding: .utf8) == "0.2.0")
    #expect(URL(fileURLWithPath: launch[4]).path.hasPrefix(box.home.upgradeStaging.path + "/"))
    #expect(box.binary == "0.1.0")
  }

  @Test(arguments: [("sha256Mismatch", false), ("badSignature", true)])
  func refusedArtifactNeverSwapsAndIsNotFetchedAgain(_ reason: String, _ badSignature: Bool) async throws {
    let box = try Box(Self.ready("0.2.0", sha: badSignature ? nil : SHA256.hex("tampered")))
    defer { box.scratch.remove() }
    let upgrader = box.upgrader(signature: { _ in if badSignature { throw MachineV2UpgradeRefusal(reason: "badSignature") } })
    await upgrader.check()
    #expect(box.launches.withLock { $0 }.isEmpty)
    #expect(box.binary == "0.1.0")
    #expect(box.state.failed?.version == "0.2.0")
    #expect(box.state.failed?.reason == reason)
    #expect(!FileManager.default.fileExists(atPath: box.home.upgradeStaging.path))
    await upgrader.check()
    #expect(box.downloads.withLock { $0 }.count == 1)
  }

  @Test func failedHealthRollsBackReportsAndRetriesOnlyANewTarget() async throws {
    let box = try Box(Self.ready("0.2.0"))
    defer { box.scratch.remove() }
    await box.upgrader().check()
    let launch = try #require(box.launches.withLock { $0 }.first)
    let candidate = launch[4]
    await withDependencies { $0.continuousClock = ImmediateClock() } operation: { await box.apply(launch) }
    #expect(box.binary == "0.1.0")
    #expect(box.state.trial == nil)
    #expect(box.state.failed?.version == "0.2.0")
    #expect(box.state.failed?.reason == "healthCheckFailed")
    #expect(box.commands.withLock { $0 }.filter { $0.contains("restart") }.count == 2)
    #expect(!FileManager.default.fileExists(atPath: URL(fileURLWithPath: candidate).deletingLastPathComponent().deletingLastPathComponent().path))

    let restarted = box.upgrader()
    await restarted.check()
    #expect(box.downloads.withLock { $0 }.count == 1)

    let described = MachineV2AutoUpgrade.reporting({ _ in try .json(MachineDescription(instance: UUID(), acceptingStarts: true, limits: OperationLimits(), kinds: [])) }, home: box.home)
    let report = try await described(Request(url: URL(string: "https://agent/machine/v2/machines/mc_test-v2")!)).body.json(MachineDescription.self).upgrade
    #expect(report?.failed?.version == "0.2.0")
    #expect(report?.failed?.reason == "healthCheckFailed")

    box.announcement.withLock { $0 = Self.ready("0.3.0") }
    await restarted.check()
    #expect(box.state.failed == nil)
    #expect(box.downloads.withLock { $0 }.last == URL(string: "https://wuhu.ai/releases/0.3.0.tar.gz")!)
    #expect(box.launches.withLock { $0 }.last?[5] == "0.3.0")
  }

  @Test func healthyConnectionCompletesTheSwap() async throws {
    let box = try Box(Self.ready("0.2.0"))
    defer { box.scratch.remove() }
    box.healthy.withLock { $0 = true }
    await box.upgrader().check()
    let launch = try #require(box.launches.withLock { $0 }.first)
    await withDependencies { $0.continuousClock = ImmediateClock() } operation: { await box.apply(launch) }
    #expect(box.binary == "0.2.0")
    #expect(try String(contentsOf: box.installer.previous, encoding: .utf8) == "0.1.0")
    #expect(box.state == MachineV2UpgradeState())
    #expect(box.commands.withLock { $0 }.filter { $0.contains("restart") }.count == 1)
  }

  @Test func onlyTheTargetAgentMarksItselfHealthy() async throws {
    let box = try Box(Self.ready("0.2.0"))
    defer { box.scratch.remove() }
    try box.home.saveUpgradeState(.init(trial: .init(version: "0.2.0", from: "0.1.0", startedAt: Date().timeIntervalSince1970)))
    await box.upgrader(running: "0.1.0").connected()
    #expect(box.state.trial?.healthyAt == nil)
    await box.upgrader(running: "0.2.0").connected()
    #expect(box.state.trial?.healthyAt != nil)
  }

  @Test func trialInProgressWaitsAndAStaleOneIsRecordedAsInterrupted() async throws {
    let box = try Box(Self.ready("0.2.0"))
    defer { box.scratch.remove() }
    let started = Date()
    try box.home.saveUpgradeState(.init(trial: .init(version: "0.2.0", from: "0.1.0", startedAt: started.timeIntervalSince1970)))
    await box.upgrader(now: started.addingTimeInterval(60)).check()
    #expect(box.downloads.withLock { $0 }.isEmpty)
    #expect(box.state.trial != nil)
    await box.upgrader(now: started.addingTimeInterval(700)).check()
    #expect(box.state.trial == nil)
    #expect(box.state.failed?.reason == "interrupted")
    #expect(box.downloads.withLock { $0 }.isEmpty)
  }

  @Test func archiveNameNeverComesFromTheURL() async throws {
    let url = "https://wuhu.ai/releases/%2e%2e%2F%2e%2e%2Foperations%2Fpoison"
    let served = URL(string: url)!.deletingPathExtension().deletingPathExtension().lastPathComponent
    let box = try Box(MachineV2Upgrade(version: "0.2.0", pinned: false, status: .ready, artifacts: [
      MachineV2Artifact(platform: "linux-amd64", url: url, sha256: SHA256.hex(served)),
    ]))
    defer { box.scratch.remove() }
    await box.upgrader().check()
    let archive = try #require(box.archives.withLock { $0 }.first)
    #expect(archive.lastPathComponent == "artifact")
    #expect(archive.deletingLastPathComponent().deletingLastPathComponent().path == box.home.upgradeStaging.path)
    #expect(!FileManager.default.fileExists(atPath: box.home.operationsDirectory.appendingPathComponent("poison").path))
    #expect(!FileManager.default.fileExists(atPath: box.home.directory.appendingPathComponent("operations/poison").path))
    #expect(box.launches.withLock { $0 }.isEmpty)
    #expect(box.state.failed?.reason == "versionMismatch")
  }

  /// Each sleep lands at its deadline plus `overshoot`, as after a suspension.
  final class SteppingClock: NonsendingClock {
    struct Instant: InstantProtocol, Hashable {
      var offset: Swift.Duration
      func advanced(by duration: Swift.Duration) -> Self { .init(offset: offset + duration) }
      func duration(to other: Self) -> Swift.Duration { other.offset - offset }
      static func < (lhs: Self, rhs: Self) -> Bool { lhs.offset < rhs.offset }
    }

    let current = Mutex(Instant(offset: .zero))
    let sleeps = Mutex(0)
    let overshoot: Swift.Duration
    let slept: @Sendable (_ count: Int, _ from: Swift.Duration, _ to: Swift.Duration) -> Void
    init(overshoot: Swift.Duration = .zero, slept: @escaping @Sendable (_ count: Int, _ from: Swift.Duration, _ to: Swift.Duration) -> Void) { self.overshoot = overshoot; self.slept = slept }
    var now: Instant { current.withLock { $0 } }
    var minimumResolution: Swift.Duration { .zero }
    func sleep(until deadline: Instant, tolerance _: Swift.Duration?) async throws {
      try Task.checkCancellation()
      let (from, to) = current.withLock { now in
        defer { now = max(now, deadline).advanced(by: overshoot) }
        return (now.offset, max(now, deadline).advanced(by: overshoot).offset)
      }
      slept(sleeps.withLock { $0 += 1; return $0 }, from, to)
    }
  }

  final class WallClock: Sendable {
    let date = Mutex(Date())
    var now: Date { date.withLock { $0 } }
  }

  static func mark(_ box: Box, at time: Date) {
    var state = box.home.loadUpgradeState()
    state.trial?.healthyAt = time.timeIntervalSince1970
    try? box.home.saveUpgradeState(state)
  }

  @Test func aMarkInTheLastInstantBeforeTheDeadlineCounts() async throws {
    let box = try Box(Self.ready("0.2.0"))
    defer { box.scratch.remove() }
    await box.upgrader().check()
    let launch = try #require(box.launches.withLock { $0 }.first)
    let installed = Date()
    let appears = Swift.Duration.milliseconds(89950)
    let clock = SteppingClock { _, from, to in
      if from < appears, appears <= to { Self.mark(box, at: installed) }
    }
    await withDependencies { $0.continuousClock = clock } operation: { await box.apply(launch, now: { installed }) }
    #expect(clock.sleeps.withLock { $0 } == MachineV2AutoUpgrade.healthSeconds)
    #expect(box.binary == "0.2.0")
    #expect(box.state == MachineV2UpgradeState())
    #expect(box.commands.withLock { $0 }.filter { $0.contains("restart") }.count == 1)
  }

  @Test(arguments: [-3600.0, 3600.0])
  func aWallClockStepNeitherAdmitsNorRejectsAMark(_ step: Double) async throws {
    for late in [false, true] {
      let box = try Box(Self.ready("0.2.0"))
      defer { box.scratch.remove() }
      await box.upgrader().check()
      let launch = try #require(box.launches.withLock { $0 }.first)
      let wall = WallClock()
      let onTime = wall.now
      let clock = SteppingClock(overshoot: late ? .seconds(120) : .zero) { count, _, _ in
        if count == 1 { wall.date.withLock { $0 = $0.addingTimeInterval(step) } }
        if count == 2 || late { Self.mark(box, at: late ? onTime : wall.now) }
      }
      await withDependencies { $0.continuousClock = clock } operation: { await box.apply(launch, now: { wall.now }) }
      #expect(box.binary == (late ? "0.1.0" : "0.2.0"))
      #expect(box.state.failed?.reason == (late ? "healthCheckFailed" : nil))
    }
  }

  @Test(arguments: [nil, 150.0])
  func aSuspendedHelperRollsBackAtItsDeadline(_ markedAfter: Double?) async throws {
    let box = try Box(Self.ready("0.2.0"))
    defer { box.scratch.remove() }
    await box.upgrader().check()
    let launch = try #require(box.launches.withLock { $0 }.first)
    let installed = Date()
    let clock = SteppingClock(overshoot: .seconds(200)) { _, _, _ in
      if let markedAfter { Self.mark(box, at: installed.addingTimeInterval(markedAfter)) }
    }
    await withDependencies { $0.continuousClock = clock } operation: { await box.apply(launch, now: { installed }) }
    #expect(clock.sleeps.withLock { $0 } == 1)
    #expect(box.binary == "0.1.0")
    #expect(box.state.trial == nil)
    #expect(box.state.failed?.reason == "healthCheckFailed")
    #expect(box.commands.withLock { $0 }.filter { $0.contains("restart") }.count == 2)
  }

  @Test func aStaleTrialOfTheRunningVersionIsReportedAndRolledBack() async throws {
    let box = try Box(Self.ready("0.2.0"))
    defer { box.scratch.remove() }
    let started = Date()
    try box.home.saveUpgradeState(.init(trial: .init(version: "0.2.0", from: "0.1.0", startedAt: started.timeIntervalSince1970, owner: "gone")))
    await box.upgrader(running: "0.2.0", now: started.addingTimeInterval(700)).check()
    #expect(box.state.trial == nil)
    #expect(box.state.rollback == .init(version: "0.2.0", to: "0.1.0"))
    #expect(box.state.failed?.version == "0.2.0")
    #expect(box.state.failed?.reason == "interrupted")
    #expect(box.launches.withLock { $0 } == [[box.home.binary.path, "machine-v2", "rollback", "mc_test-v2"]])
    #expect(box.downloads.withLock { $0 }.isEmpty)
  }

  @Test func anUnfinishedRollbackIsRetriedUntilTheOldVersionRuns() async throws {
    let box = try Box(Self.ready("0.2.0"))
    defer { box.scratch.remove() }
    let started = Date()
    try box.home.saveUpgradeState(.init(trial: .init(version: "0.2.0", from: "0.1.0", startedAt: started.timeIntervalSince1970, owner: "gone")))
    let unproved = box.upgrader(running: "0.2.0", now: started.addingTimeInterval(700))
    box.launchFails.withLock { $0 = true }
    await unproved.check()
    #expect(box.launches.withLock { $0 }.isEmpty)
    #expect(box.state.rollback == .init(version: "0.2.0", to: "0.1.0"))
    box.launchFails.withLock { $0 = false }
    await unproved.connected()
    await unproved.check()
    await unproved.check()
    let rollback = [box.home.binary.path, "machine-v2", "rollback", "mc_test-v2"]
    #expect(box.launches.withLock { $0 } == [rollback, rollback])
    #expect(box.state.rollback != nil)
    #expect(box.state.trial == nil)
    #expect(box.state.failed?.reason == "interrupted")
    #expect(box.downloads.withLock { $0 }.isEmpty)

    await box.upgrader(running: "0.1.0").check()
    #expect(box.state.rollback == nil)
    #expect(box.state.failed?.version == "0.2.0")
    #expect(box.state.failed?.reason == "interrupted")
    #expect(box.downloads.withLock { $0 }.isEmpty)
    #expect(box.launches.withLock { $0 }.count == 2)
  }

  @Test func aStaleTrialThatConnectedIsDone() async throws {
    let box = try Box(Self.ready("0.2.0"))
    defer { box.scratch.remove() }
    let started = Date()
    try box.home.saveUpgradeState(.init(trial: .init(version: "0.2.0", from: "0.1.0", startedAt: started.timeIntervalSince1970, healthyAt: started.timeIntervalSince1970 + 5, owner: "gone")))
    await box.upgrader(running: "0.2.0", now: started.addingTimeInterval(700)).check()
    #expect(box.state == MachineV2UpgradeState())
    #expect(box.launches.withLock { $0 }.isEmpty)
  }

  @Test func theReservationPrecedesTheHelperAndBlocksASecondLaunch() async throws {
    let box = try Box(Self.ready("0.2.0"))
    defer { box.scratch.remove() }
    let upgrader = box.upgrader()
    await upgrader.check()
    await upgrader.check()
    await box.upgrader().check()
    #expect(box.launches.withLock { $0 }.count == 1)
    #expect(box.downloads.withLock { $0 }.count == 1)
    #expect(box.state.trial?.owner == box.launches.withLock { $0 }.first?[6])
  }

  @Test func aFailedSpawnReleasesTheReservation() async throws {
    let box = try Box(Self.ready("0.2.0"))
    defer { box.scratch.remove() }
    box.launchFails.withLock { $0 = true }
    await box.upgrader().check()
    #expect(box.state.trial == nil)
    #expect(box.state.failed == nil)
    #expect(!FileManager.default.fileExists(atPath: box.home.upgradeStaging.path))
  }

  @Test func aHelperWithAForeignTokenLeavesTheTrialAlone() async throws {
    let box = try Box(Self.ready("0.2.0"))
    defer { box.scratch.remove() }
    box.healthy.withLock { $0 = true }
    await box.upgrader().check()
    let launch = try #require(box.launches.withLock { $0 }.first)
    let reserved = box.state
    var forged = launch
    forged[6] = UUID().uuidString
    await withDependencies { $0.continuousClock = ImmediateClock() } operation: { await box.apply(forged) }
    #expect(box.state == reserved)
    #expect(box.binary == "0.1.0")
    #expect(box.commands.withLock { $0 }.isEmpty)
    #expect(FileManager.default.fileExists(atPath: launch[4]))
  }

  @Test func aLinuxHostPreflightFailureIsRetriedAtTheNextCheck() async throws {
    let box = try Box(Self.ready("0.2.0"))
    defer { box.scratch.remove() }
    await box.upgrader().check()
    let launch = try #require(box.launches.withLock { $0 }.first)
    let installer = MachineV2Installer(home: box.installer.home, machine: box.installer.machine, platform: .linux, userID: 501, command: { _ in "" })
    await withDependencies { $0.continuousClock = ImmediateClock() } operation: { await box.apply(launch, installer: installer) }
    #expect(box.state == MachineV2UpgradeState())
    #expect(box.binary == "0.1.0")
    #expect(!FileManager.default.fileExists(atPath: launch[4]))
    await box.upgrader().check()
    #expect(box.downloads.withLock { $0 }.count == 2)
    #expect(box.launches.withLock { $0 }.count == 2)
  }

  @Test func aMacPreflightFailureRecordsTheTargetAsFailed() async throws {
    let box = try Box(Self.ready("0.2.0"))
    defer { box.scratch.remove() }
    await box.upgrader().check()
    let launch = try #require(box.launches.withLock { $0 }.first)
    let installer = MachineV2Installer(home: box.installer.home, machine: box.installer.machine, platform: .macOS, userID: 501, command: { arguments in
      if arguments.count > 1, arguments[1] == "print" { throw CommandFailure(command: arguments, status: 113, stderr: "Could not find service") }
      if arguments.count > 1, arguments[1] == "bootstrap", let plist = arguments.last, plist.hasSuffix(".preflight.plist") {
        let definition = try String(contentsOf: URL(fileURLWithPath: plist), encoding: .utf8)
        let receipt = try #require(definition.split(separator: "<string>").map { String($0.prefix { $0 != "<" }) }.first { $0.hasSuffix(".json") })
        try Data(#"{"ok":false,"message":"the candidate crashed"}"#.utf8).write(to: URL(fileURLWithPath: receipt))
      }
      return ""
    })
    await withDependencies { $0.continuousClock = ImmediateClock() } operation: { await box.apply(launch, installer: installer) }
    #expect(box.state.trial == nil)
    #expect(box.state.failed?.version == "0.2.0")
    #expect(box.state.failed?.reason == "installFailed")
    #expect(box.binary == "0.1.0")
    await box.upgrader().check()
    #expect(box.downloads.withLock { $0 }.count == 1)
    #expect(box.launches.withLock { $0 }.count == 1)
  }

  /// A busy installer (`replaced` false) and a Linux preflight failing under the lock (`replaced` true, the trial
  /// replaced meanwhile) both defer to the next check, clearing the trial only while it is still this helper's.
  @Test(arguments: [false, true])
  func aDeferredInstallClearsOnlyItsOwnTrial(_ replaced: Bool) async throws {
    let box = try Box(Self.ready("0.2.0"))
    defer { box.scratch.remove() }
    await box.upgrader().check()
    let launch = try #require(box.launches.withLock { $0 }.first)
    let lock = open(box.installer.root.appendingPathComponent(".install-lock").path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
    defer { close(lock) }
    if !replaced { #expect(flock(lock, LOCK_EX | LOCK_NB) == 0) }
    let other = MachineV2UpgradeState.Trial(version: "0.2.0", from: "0.1.0", startedAt: 1, owner: "other")
    let installer = MachineV2Installer(home: box.installer.home, machine: box.installer.machine, platform: .linux, userID: 501, command: { arguments in
      if arguments.first == "/usr/bin/loginctl" {
        try box.home.saveUpgradeState(.init(trial: other))
        return "no\n"
      }
      return arguments == ["/usr/bin/id", "-un"] ? "agent\n" : ""
    })
    await withDependencies { $0.continuousClock = ImmediateClock() } operation: { await box.apply(launch, installer: installer) }
    #expect(box.state.trial == (replaced ? other : nil))
    #expect(box.state.failed == nil)
    #expect(box.binary == "0.1.0")
  }
}
