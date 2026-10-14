@testable import CLIKit
import Foundation
import Scratch
import Synchronization
import Testing
#if os(Linux)
  import Glibc
#else
  import Darwin
#endif

@Suite struct MachineV2InstallerTests {
  final class Effects: Sendable {
    let commands = Mutex<[[String]]>([])
    let fail = Mutex(false)
    func run(_ arguments: [String]) throws -> String {
      self.commands.withLock { $0.append(arguments) }
      if self.fail.withLock({ $0 }) { throw CLIError(message: "service manager refused") }
      return ""
    }
  }

  func fixture(_ effects: Effects) throws -> (ScratchFolder, URL, MachineV2Installer, URL) {
    let scratch = try ScratchFolder("machine-v2-installer")
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: scratch.path)
    let resolved = try #require(realpath(scratch.path, nil))
    defer { free(resolved) }
    let home = URL(fileURLWithPath: String(cString: resolved))
    let candidate = home.appendingPathComponent("candidate")
    try Data("new signed artifact".utf8).write(to: candidate)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: candidate.path)
    return (scratch, home, MachineV2Installer(home: home, machine: "mc_test-v2", platform: .linux, userID: 501, command: { try effects.run($0) }), candidate)
  }

  @Test func isolatedInstallUpgradeRollbackAndDrain() async throws {
    let effects = Effects()
    let (scratch, home, installer, candidate) = try self.fixture(effects)
    defer { scratch.remove() }
    let legacy = home.appendingPathComponent(".wuhu/bin/wuhu")
    try FileManager.default.createDirectory(at: legacy.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("v1".utf8).write(to: legacy)
    try await installer.install(candidate: candidate)
    #expect(try Data(contentsOf: installer.binary) == Data("new signed artifact".utf8))
    #expect(installer.serviceDefinition.contains("KillMode=process"))
    #expect(installer.serviceDefinition.contains("machine-v2 run mc_test-v2"))
    try Data("newer signed artifact".utf8).write(to: candidate)
    try await installer.install(candidate: candidate)
    #expect(try Data(contentsOf: installer.previous) == Data("new signed artifact".utf8))
    try await installer.rollback()
    #expect(try Data(contentsOf: installer.binary) == Data("new signed artifact".utf8))
    let count = effects.commands.withLock { $0.count }
    do {
      try await installer.uninstall { throw CLIError(message: "terminal acknowledgements pending") }
      Issue.record("undrained uninstall succeeded")
    } catch let error as MachineV2InstallError { #expect(error.code == .drainFailed) }
    #expect(effects.commands.withLock { $0.count } == count)
    try await installer.uninstall {
      #expect(FileManager.default.fileExists(atPath: installer.serviceFile.path))
      #expect(effects.commands.withLock { $0.count } == count)
    }
    #expect(!FileManager.default.fileExists(atPath: installer.serviceFile.path))
    #expect(try Data(contentsOf: legacy) == Data("v1".utf8))
    #expect(FileManager.default.fileExists(atPath: installer.binary.path))
  }

  @Test func crashedLockHolderDoesNotWedgeInstallRollbackOrUninstall() async throws {
    let effects = Effects()
    let (scratch, _, installer, candidate) = try self.fixture(effects)
    defer { scratch.remove() }
    try await installer.install(candidate: candidate)
    let lockPath = installer.root.appendingPathComponent(".install-lock").path
    let fd = open(lockPath, O_RDWR)
    #expect(fd >= 0)
    guard fd >= 0 else { return }
    guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { close(fd); Issue.record("cannot hold installer lock"); return }
    let holder = Process()
    holder.executableURL = URL(fileURLWithPath: "/bin/sleep")
    holder.arguments = ["100"]
    let inherited = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    holder.standardInput = inherited
    do { try holder.run() } catch { try inherited.close(); throw error }
    try inherited.close()
    defer {
      if holder.isRunning { kill(holder.processIdentifier, SIGKILL); holder.waitUntilExit() }
    }
    let count = effects.commands.withLock { $0.count }
    for action in 0 ..< 3 {
      do {
        switch action {
        case 0: try await installer.install(candidate: candidate)
        case 1: try await installer.rollback()
        default: try await installer.uninstall { Issue.record("busy uninstall attempted leave") }
        }
        Issue.record("concurrent installer acquired held lock")
      } catch let error as MachineV2InstallError { #expect(error.code == .busy) }
    }
    #expect(effects.commands.withLock { $0.count } == count)
    kill(holder.processIdentifier, SIGKILL)
    holder.waitUntilExit()
    #expect(FileManager.default.fileExists(atPath: lockPath))
    try Data("updated after crash".utf8).write(to: candidate)
    try await installer.install(candidate: candidate)
    try await installer.rollback()
    #expect(try Data(contentsOf: installer.binary) == Data("new signed artifact".utf8))
    try await installer.uninstall {}
    #expect(!FileManager.default.fileExists(atPath: installer.serviceFile.path))
    #expect(FileManager.default.fileExists(atPath: lockPath))
  }

  @Test func lostLeaveAcknowledgementStillRemovesServiceButNeverReportsDetach() async throws {
    let effects = Effects()
    let (scratch, _, installer, candidate) = try self.fixture(effects)
    defer { scratch.remove() }
    try await installer.install(candidate: candidate)
    do {
      try await installer.uninstall { throw MachineV2RuntimeError(.leaveUnacknowledged, message: "server acknowledgement deadline") }
      Issue.record("unacknowledged leave reported success")
    } catch let error as MachineV2RuntimeError { #expect(error.code == .leaveUnacknowledged) }
    #expect(!FileManager.default.fileExists(atPath: installer.serviceFile.path))
    #expect(effects.commands.withLock { $0.contains(["/usr/bin/systemctl", "--user", "disable", "--now", installer.unit]) })
  }

  @Test func serviceFailureKeepsExplicitRollback() async throws {
    let effects = Effects()
    let (scratch, _, installer, candidate) = try self.fixture(effects)
    defer { scratch.remove() }
    try await installer.install(candidate: candidate)
    try Data("updated".utf8).write(to: candidate)
    effects.fail.withLock { $0 = true }
    do { try await installer.install(candidate: candidate); Issue.record("expected service failure") }
    catch let error as MachineV2InstallError { #expect(error.code == .serviceFailure) }
    #expect(try Data(contentsOf: installer.binary) == Data("updated".utf8))
    #expect(try Data(contentsOf: installer.previous) == Data("new signed artifact".utf8))
  }

  @Test func launchdNetworkDenialIsTypedWithoutInteractiveFallback() async throws {
    let effects = Effects()
    let (scratch, _, original, candidate) = try self.fixture(effects)
    defer { scratch.remove() }
    var installer = original
    installer.platform = .macOS
    try FileManager.default.createDirectory(at: installer.binary.deletingLastPathComponent(), withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: installer.serviceFile.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("live".utf8).write(to: installer.binary)
    try Data("previous".utf8).write(to: installer.previous)
    try Data("existing service".utf8).write(to: installer.serviceFile)
    installer.command = { arguments in
      _ = try effects.run(arguments)
      if arguments.count == 4, arguments[1] == "bootstrap", arguments[3].hasSuffix(".preflight.plist") {
        let plist = try PropertyListSerialization.propertyList(from: Data(contentsOf: URL(fileURLWithPath: arguments[3])), format: nil) as! [String: Any]
        let argv = plist["ProgramArguments"] as! [String]
        try Data(#"{"ok":false,"code":"localNetworkDenied","message":"grant Local Network under launchd"}"#.utf8).write(to: URL(fileURLWithPath: argv.last!))
      }
      return ""
    }
    do { try await installer.install(candidate: candidate); Issue.record("denied preflight installed a service") }
    catch let error as MachineV2InstallError { #expect(error.code == .localNetworkDenied) }
    #expect(try Data(contentsOf: installer.binary) == Data("live".utf8))
    #expect(try Data(contentsOf: installer.previous) == Data("previous".utf8))
    #expect(try Data(contentsOf: installer.serviceFile) == Data("existing service".utf8))
    #expect(effects.commands.withLock { $0.allSatisfy { $0[0] == "/bin/launchctl" } })
    #expect(effects.commands.withLock { $0.last } == ["/bin/launchctl", "bootout", "gui/501/ai.wuhu.machine-v2.mc_test-v2.preflight"])
  }

  @Test func launchdRetryAcceptsOnlyExplicitNotLoadedBootout() async throws {
    let effects = Effects()
    let (scratch, _, original, candidate) = try self.fixture(effects)
    defer { scratch.remove() }
    var installer = original
    installer.platform = .macOS
    let failBootstrap = Mutex(true)
    let bootoutFailure = Mutex("Could not find specified service")
    installer.command = { arguments in
      _ = try effects.run(arguments)
      if arguments[1] == "bootout" { throw CLIError(message: bootoutFailure.withLock { $0 }) }
      if arguments[1] == "bootstrap", arguments.last!.hasSuffix(".preflight.plist") {
        let plist = try PropertyListSerialization.propertyList(from: Data(contentsOf: URL(fileURLWithPath: arguments.last!)), format: nil) as! [String: Any]
        let argv = plist["ProgramArguments"] as! [String]
        try Data(#"{"ok":true}"#.utf8).write(to: URL(fileURLWithPath: argv.last!))
      } else if arguments[1] == "bootstrap", failBootstrap.withLock({ value in let fail = value; value = false; return fail }) {
        throw CLIError(message: "bootstrap refused once")
      }
      return ""
    }
    do { try await installer.install(candidate: candidate); Issue.record("expected initial bootstrap failure") }
    catch let error as MachineV2InstallError { #expect(error.code == .serviceFailure) }
    #expect(FileManager.default.fileExists(atPath: installer.serviceFile.path))
    try await installer.install(candidate: candidate)
    bootoutFailure.withLock { $0 = "Boot-out failed: 5: Input/output error" }
    do { try await installer.uninstall {}; Issue.record("genuine bootout error ignored") }
    catch let error as MachineV2InstallError { #expect(error.code == .serviceFailure) }
    #expect(FileManager.default.fileExists(atPath: installer.serviceFile.path))
    bootoutFailure.withLock { $0 = "Boot-out failed: 3: No such process" }
    try await installer.uninstall {}
    #expect(!FileManager.default.fileExists(atPath: installer.serviceFile.path))
    try await installer.uninstall {}
  }

  @Test func launchdDefinitionPreservesSupervisorGroupsAndEscapesPaths() throws {
    let effects = Effects()
    let (scratch, home, original, _) = try self.fixture(effects)
    defer { scratch.remove() }
    var installer = original
    installer.platform = .macOS
    installer.home = home.appendingPathComponent("space & name")
    let data = Data(installer.serviceDefinition.utf8)
    let plist = try PropertyListSerialization.propertyList(from: data, format: nil) as! [String: Any]
    #expect(plist["AbandonProcessGroup"] as? Bool == true)
    #expect(plist["Label"] as? String == "ai.wuhu.machine-v2.mc_test-v2")
    #expect(plist["ProgramArguments"] as? [String] == [installer.binary.path, "machine-v2", "run", installer.machine])
  }

  @Test func unsafeIDAndSymlinkCannotTouchOtherInstallations() async throws {
    let effects = Effects()
    let (scratch, home, original, candidate) = try self.fixture(effects)
    defer { scratch.remove() }
    var installer = original
    installer.machine = "../../bin"
    await #expect(throws: MachineV2InstallError.self) { try await installer.install(candidate: candidate) }
    let legacy = home.appendingPathComponent(".wuhu")
    try FileManager.default.createSymbolicLink(at: legacy, withDestinationURL: home)
    installer = original
    await #expect(throws: MachineV2InstallError.self) { try await installer.install(candidate: candidate) }
    #expect(effects.commands.withLock { $0.isEmpty })
  }
}
