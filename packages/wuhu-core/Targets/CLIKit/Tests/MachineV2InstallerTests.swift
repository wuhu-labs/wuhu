@testable import CLIKit
import Crypto
import Fetch
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
      if arguments.count > 1, arguments[1] == "print" { throw CommandFailure(command: arguments, status: 113, stderr: "Could not find service") }
      if arguments == ["/usr/bin/id", "-un"] { return "recording-user\n" }
      if arguments.first == "/usr/bin/loginctl" { return "yes\n" }
      if arguments == ["/usr/bin/systemctl", "--user", "show-environment"] { return "" }
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
    // A revoked agent exits 0 and stays down; a crash or any failure still restarts.
    #expect(installer.serviceDefinition.contains("Restart=always\nRestartPreventExitStatus=0\n"))
    // No start limit: a rollback's restart after a crash-looping version must never be refused.
    #expect(installer.serviceDefinition.contains("[Unit]\nDescription=Wuhu machine v2 (mc_test-v2)\nAfter=network-online.target\nStartLimitIntervalSec=0\n[Service]\n"))
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

  @Test func completedMutationUnlocksWhileDuplicateDescriptorIsRetained() async throws {
    let effects = Effects()
    let (scratch, _, original, candidate) = try self.fixture(effects)
    defer { scratch.remove() }
    let inherited = Mutex<Int32?>(nil)
    let lockPath = original.root.appendingPathComponent(".install-lock").path
    var installer = original
    installer.command = { arguments in
      if arguments == ["/usr/bin/systemctl", "--user", "daemon-reload"], inherited.withLock({ $0 == nil }) {
        let descriptor = try duplicateOpenDescriptor(path: lockPath)
        inherited.withLock { $0 = descriptor }
      }
      return try effects.run(arguments)
    }
    defer { if let descriptor = inherited.withLock({ $0 }) { close(descriptor) } }
    try await installer.install(candidate: candidate)
    #expect(inherited.withLock { $0 != nil })
    do {
      try await installer.uninstall { throw CLIError(message: "still draining") }
      Issue.record("undrained uninstall succeeded")
    } catch let error as MachineV2InstallError { #expect(error.code == .drainFailed) }
    try await installer.install(candidate: candidate)
  }

  @Test func crashedLockHolderDoesNotWedgeInstallRollbackOrUninstall() async throws {
    let effects = Effects()
    let (scratch, _, installer, candidate) = try self.fixture(effects)
    defer { scratch.remove() }
    try await installer.install(candidate: candidate)
    let lockPath = installer.root.appendingPathComponent(".install-lock").path
    let fd = open(lockPath, O_RDWR | O_CLOEXEC)
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
    #expect(effects.commands.withLock { Array($0.dropFirst(count)) } == [["/usr/bin/id", "-un"], ["/usr/bin/loginctl", "show-user", "recording-user", "-p", "Linger", "--value"], ["/usr/bin/systemctl", "--user", "show-environment"]])
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

  @Test(arguments: [MachineV2Installer.Platform.linux, .macOS]) func anUpgradeSwapsTheBinaryAndLeavesTheDefinitionAsInstalled(_ platform: MachineV2Installer.Platform) async throws {
    let effects = Effects()
    let (scratch, _, original, candidate) = try self.fixture(effects)
    defer { scratch.remove() }
    var installer = original
    installer.platform = platform
    installer.command = { arguments in
      let output = try effects.run(arguments)
      if arguments.count == 4, arguments[1] == "bootstrap", arguments[3].hasSuffix(".preflight.plist") {
        let plist = try PropertyListSerialization.propertyList(from: Data(contentsOf: URL(fileURLWithPath: arguments[3])), format: nil) as! [String: Any]
        try Data(#"{"ok":true}"#.utf8).write(to: URL(fileURLWithPath: (plist["ProgramArguments"] as! [String]).last!))
      }
      return output
    }
    try FileManager.default.createDirectory(at: installer.serviceFile.deletingLastPathComponent(), withIntermediateDirectories: true)
    let edited = Data("an older definition, edited by hand".utf8)
    try edited.write(to: installer.serviceFile)
    try await installer.upgrade(candidate: candidate)
    #expect(try Data(contentsOf: installer.binary) == Data("new signed artifact".utf8))
    #expect(try Data(contentsOf: installer.serviceFile) == edited)
    let service = effects.commands.withLock { $0 }.filter { ["/usr/bin/systemctl", "/bin/launchctl"].contains($0[0]) && !["show-environment", "print"].contains($0.last!) && $0[1] != "print" }
    switch platform {
    case .linux: #expect(service == [["/usr/bin/systemctl", "--user", "restart", installer.unit]])
    case .macOS: #expect(service.suffix(2) == [["/bin/launchctl", "bootout", "gui/501/\(installer.label)"], ["/bin/launchctl", "bootstrap", "gui/501", installer.serviceFile.path]])
    }
  }

  /// `wuhu machine-v2 upgrade` is the installer's upgrade, not an alias of install: a hand edit to the definition
  /// survives it. Once an uninstall has removed the definition, as one can between the verb starting and the
  /// installer taking its lock, it refuses under that lock, names install, and leaves `bin/` and the service alone.
  @Test func theUpgradeVerbKeepsAHandEditedDefinition() async throws {
    let effects = Effects()
    let (scratch, home, _, candidate) = try self.fixture(effects)
    defer { scratch.remove() }
    let enrollment = MachineV2Home(root: home.appendingPathComponent(".wuhu/machine-v2"), machine: "mc_test-v2")
    try enrollment.save(.init(machine: "mc_test-v2", name: "box-v2", server: "https://example.test"), key: .init())
    let runner = CommandRunner(
      fetch: FetchClient { _ in Response(status: .ok) }, stdin: { "" }, stdout: { _ in }, stderr: { _ in },
      environment: ["HOME": home.path], currentDirectory: home.path,
      machineV2ServiceCommand: { arguments in
        // The Linux installer runs every service-manager command under `/usr/bin/env XDG_RUNTIME_DIR=…`.
        let arguments = arguments.first == "/usr/bin/env" ? Array(arguments.dropFirst(2)) : arguments
        let output = try effects.run(arguments)
        if arguments.count == 4, arguments[1] == "bootstrap", arguments[3].hasSuffix(".preflight.plist") {
          let plist = try PropertyListSerialization.propertyList(from: Data(contentsOf: URL(fileURLWithPath: arguments[3])), format: nil) as! [String: Any]
          try Data(#"{"ok":true}"#.utf8).write(to: URL(fileURLWithPath: (plist["ProgramArguments"] as! [String]).last!))
        }
        return output
      },
    )
    let installer = MachineV2Installer.local(home: home, machine: "mc_test-v2", environment: [:], command: { _ in "" })
    func run(_ verb: String) async throws -> MachineV2InstallCommand {
      guard case let .machineV2Install(command) = try Command.parse(["machine-v2", verb, "mc_test-v2", "--binary", candidate.path]) else {
        throw CLIError(message: "\(verb) did not select the installer")
      }
      try await runner.runMachineV2Install(command)
      return command
    }
    #expect(try await run("install") == .install(machine: "mc_test-v2", binary: candidate.path))
    let edited = Data((try String(contentsOf: installer.serviceFile, encoding: .utf8) + (installer.platform == .linux ? "# edited by hand\n" : "<!-- edited by hand -->\n")).utf8)
    try edited.write(to: installer.serviceFile)
    try Data("an upgrade".utf8).write(to: candidate)
    effects.commands.withLock { $0.removeAll() }
    #expect(try await run("upgrade") == .upgrade(machine: "mc_test-v2", binary: candidate.path))
    #expect(try Data(contentsOf: installer.serviceFile) == edited)
    #expect(try Data(contentsOf: installer.binary) == Data("an upgrade".utf8))
    #expect(try Data(contentsOf: installer.previous) == Data("new signed artifact".utf8))
    #expect(!effects.commands.withLock { $0 }.contains { $0.contains("daemon-reload") || $0.contains("enable") })

    try FileManager.default.removeItem(at: installer.serviceFile)
    try Data("never installed".utf8).write(to: candidate)
    let bin = installer.binary.deletingLastPathComponent()
    func snapshot() throws -> [String: Data] {
      try Dictionary(uniqueKeysWithValues: FileManager.default.contentsOfDirectory(atPath: bin.path).map { ($0, try Data(contentsOf: bin.appendingPathComponent($0))) })
    }
    let before = try snapshot()
    effects.commands.withLock { $0.removeAll() }
    do { _ = try await run("upgrade"); Issue.record("upgrade without a definition succeeded") }
    catch let error as CLIError { #expect(error.message.contains("wuhu machine-v2 install mc_test-v2")) }
    #expect(try snapshot() == before)
    #expect(!FileManager.default.fileExists(atPath: installer.serviceFile.path))
    #expect(effects.commands.withLock { $0 }.isEmpty)
  }

  @Test func onlyTheInstalledJobStopsItself() async throws {
    let effects = Effects()
    let (scratch, _, installer, _) = try self.fixture(effects)
    defer { scratch.remove() }
    let unit = "0::/user.slice/user-501.slice/user@501.service/app.slice/wuhu-machine-v2@mc_test-v2.service\n"
    let linux = try #require(MachineV2Service(installer, environment: [:], controlGroups: unit))
    try await linux.stop()
    #expect(effects.commands.withLock { $0 } == [["/usr/bin/systemctl", "--user", "stop", "wuhu-machine-v2@mc_test-v2.service"]])
    #expect(MachineV2Service(installer, environment: [:], controlGroups: "0::/user.slice/user-501.slice/session-1.scope\n") == nil)
    #expect(MachineV2Service(installer, environment: [:], controlGroups: nil) == nil)
    var mac = installer
    mac.platform = .macOS
    #expect(MachineV2Service(mac, environment: ["XPC_SERVICE_NAME": "0"], controlGroups: unit) == nil)
    let job = try #require(MachineV2Service(mac, environment: ["XPC_SERVICE_NAME": mac.label], controlGroups: nil))
    effects.commands.withLock { $0 = [] }
    try await job.stop()
    #expect(effects.commands.withLock { $0.first } == ["/bin/launchctl", "bootout", "gui/501/\(mac.label)"])
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
    #expect(effects.commands.withLock { $0.suffix(2).map { $0[1] } } == ["bootout", "print"])
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

  @Test func launchdInstallPreservesSupervisorGroupsAndEscapesPaths() async throws {
    let effects = Effects()
    let (scratch, home, original, candidate) = try self.fixture(effects)
    defer { scratch.remove() }
    var installer = original
    installer.platform = .macOS
    installer.home = home.appendingPathComponent("space & name")
    installer.command = { arguments in
      _ = try effects.run(arguments)
      if arguments[1] == "bootstrap", arguments.last!.hasSuffix(".preflight.plist") {
        let definition = try Data(contentsOf: URL(fileURLWithPath: arguments.last!))
        let plist = try PropertyListSerialization.propertyList(from: definition, format: nil) as! [String: Any]
        let argv = plist["ProgramArguments"] as! [String]
        try Data(#"{"ok":true}"#.utf8).write(to: URL(fileURLWithPath: argv.last!))
      }
      return ""
    }
    try await installer.install(candidate: candidate)
    let data = try Data(contentsOf: installer.serviceFile)
    let plist = try PropertyListSerialization.propertyList(from: data, format: nil) as! [String: Any]
    #expect(plist["AbandonProcessGroup"] as? Bool == true)
    #expect(plist["Label"] as? String == "ai.wuhu.machine-v2.mc_test-v2")
    #expect(plist["ProgramArguments"] as? [String] == [installer.binary.path, "machine-v2", "run", installer.machine])
    #expect(plist["KeepAlive"] as? [String: Bool] == ["SuccessfulExit": false])
    #expect(plist["EnvironmentVariables"] as? [String: String] == ["PATH": installer.home.path + "/.wuhu/bin:/opt/homebrew/bin:/opt/homebrew/sbin:/usr/bin:/bin:/usr/sbin:/sbin"])
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

extension MachineV2InstallerTests {
  @Test(arguments: ["linger-off", "linger-error", "bus-error", "missing-binary"])
  func linuxPreflightFailsBeforeAnyInstallationWrites(_ failure: String) async throws {
    let effects = Effects()
    let (scratch, home, original, candidate) = try fixture(effects)
    defer { scratch.remove() }
    var installer = original
    installer.command = { arguments in
      if arguments.first == "/usr/bin/loginctl" {
        if failure == "linger-off" { return "no\n" }
        if failure == "linger-error" { throw CLIError(message: "no user session") }
      }
      if arguments.last == "show-environment", failure == "bus-error" { throw CLIError(message: "Failed to connect to bus") }
      return try effects.run(arguments)
    }
    if failure == "missing-binary" { try FileManager.default.removeItem(at: candidate) }
    do { try await installer.install(candidate: candidate); Issue.record("preflight failure installed") }
    catch let error as MachineV2InstallError {
      #expect(error.code == (failure == "missing-binary" ? .missingBinary : .preflightFailed))
      if failure.hasPrefix("linger") { #expect(error.message.contains("sudo loginctl enable-linger recording-user")) }
      if failure == "bus-error" { #expect(error.message.contains("Failed to connect to bus")) }
    }
    #expect(!FileManager.default.fileExists(atPath: home.appendingPathComponent(".wuhu").path))
    #expect(!FileManager.default.fileExists(atPath: installer.serviceFile.path))
    #expect(try FileManager.default.contentsOfDirectory(atPath: home.path) == (failure == "missing-binary" ? [] : ["candidate"]))
  }

  @Test func failedLinuxPreflightPreservesInstalledBinaryUnitAndPreviousArtifact() async throws {
    let effects = Effects()
    let (scratch, _, original, candidate) = try fixture(effects)
    defer { scratch.remove() }
    try await original.install(candidate: candidate)
    try Data("backup".utf8).write(to: original.previous)
    let oldBinary = try Data(contentsOf: original.binary)
    let oldUnit = try Data(contentsOf: original.serviceFile)
    try Data("upgrade".utf8).write(to: candidate)
    var installer = original
    installer.command = { arguments in
      if arguments.first == "/usr/bin/loginctl" { return "no" }
      return try effects.run(arguments)
    }
    await #expect(throws: MachineV2InstallError.self) { try await installer.install(candidate: candidate) }
    #expect(try Data(contentsOf: installer.binary) == oldBinary)
    #expect(try Data(contentsOf: installer.serviceFile) == oldUnit)
    #expect(try Data(contentsOf: installer.previous) == Data("backup".utf8))
    #expect(try FileManager.default.contentsOfDirectory(atPath: installer.binary.deletingLastPathComponent().path).sorted() == ["previous", "wuhu"])
  }

  @Test func linuxServiceCommandsDeriveRuntimeDirectoryAndPreserveExplicitValue() {
    let command = ["/usr/bin/systemctl", "--user", "daemon-reload"]
    for environment in [[:], ["XDG_RUNTIME_DIR": ""]] {
      #expect(machineV2ServiceArguments(command, platform: .linux, environment: environment, userID: 123) == ["/usr/bin/env", "XDG_RUNTIME_DIR=/run/user/123"] + command)
    }
    #expect(machineV2ServiceArguments(command, platform: .linux, environment: ["XDG_RUNTIME_DIR": "/custom/runtime"], userID: 123) == ["/usr/bin/env", "XDG_RUNTIME_DIR=/custom/runtime"] + command)
    #expect(machineV2ServiceArguments(command, platform: .macOS, environment: [:], userID: 123) == command)
  }
}

private func duplicateOpenDescriptor(path: String) throws -> Int32 {
  var target = stat()
  guard stat(path, &target) == 0 else { throw CLIError(message: "cannot stat lock fixture") }
  for entry in try FileManager.default.contentsOfDirectory(atPath: "/dev/fd") {
    guard let descriptor = Int32(entry) else { continue }
    var info = stat()
    guard fstat(descriptor, &info) == 0, info.st_dev == target.st_dev, info.st_ino == target.st_ino else { continue }
    let duplicate = fcntl(descriptor, F_DUPFD_CLOEXEC, 0)
    guard duplicate >= 0 else { throw CLIError(message: "cannot duplicate lock fixture") }
    return duplicate
  }
  throw CLIError(message: "installer lock descriptor not found")
}
