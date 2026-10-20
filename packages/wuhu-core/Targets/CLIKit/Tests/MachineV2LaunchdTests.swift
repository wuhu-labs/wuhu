@testable import CLIKit
import Clocks
import Dependencies
import DeterministicDependencies
import Foundation
import Scratch
import Synchronization
import Testing

@Suite(.deterministicDependencies(clock: ContinuousClock())) struct MachineV2LaunchdTests {
  final class Launchctl: Sendable {
    struct State {
      var commands: [[String]] = []
      var bootstrapStatuses: [Int32] = [5, 5, 0]
      var pendingPrints = 0
      var loaded = true
      var unloadingPrints = 2
      var printFailure: Int32?
      var alreadyUnloaded = false
    }

    let state = Mutex(State())
    func run(_ arguments: [String]) throws -> String {
      try self.state.withLock { state in
        state.commands.append(arguments)
        let preflight = arguments.last!.contains(".preflight")
        switch arguments[1] {
        case "bootout":
          if !preflight {
            if state.alreadyUnloaded { throw CommandFailure(command: arguments, status: 3, stderr: "Boot-out failed: 3: No such process") }
            state.loaded = false; state.pendingPrints = state.unloadingPrints
          }
        case "print":
          if preflight { throw CommandFailure(command: arguments, status: 113, stderr: "Could not find service") }
          if let failure = state.printFailure { throw CommandFailure(command: arguments, status: failure, stderr: "print denied") }
          if state.pendingPrints > 0 { state.pendingPrints -= 1; return "service unloading" }
          if state.loaded { return "service loaded" }
          throw CommandFailure(command: arguments, status: 113, stderr: "Could not find service")
        case "bootstrap":
          if preflight {
            let plist = try PropertyListSerialization.propertyList(from: Data(contentsOf: URL(fileURLWithPath: arguments.last!)), format: nil) as! [String: Any]
            let argv = plist["ProgramArguments"] as! [String]
            try Data(#"{"ok":true}"#.utf8).write(to: URL(fileURLWithPath: argv.last!))
          } else {
            let status = state.bootstrapStatuses.isEmpty ? 0 : state.bootstrapStatuses.removeFirst()
            if status != 0 { throw CommandFailure(command: arguments, status: status, stderr: "Bootstrap failed: \(status): Input/output error") }
            state.loaded = true
          }
        default: Issue.record("unexpected launchctl verb")
        }
        return ""
      }
    }
  }

  @Test(arguments: ["install-over-existing", "upgrade", "rollback", "rollback-unloaded"])
  func installerWaitsForUnloadBeforeRetryingBootstrap(_ action: String) async throws {
    let fixture = try MachineV2InstallerTests().fixture(.init())
    defer { fixture.0.remove() }
    var installer = fixture.2
    installer.platform = .macOS
    let launchctl = Launchctl()
    if action == "rollback-unloaded" { launchctl.state.withLock { $0.loaded = false; $0.alreadyUnloaded = true } }
    installer.command = { try launchctl.run($0) }
    try FileManager.default.createDirectory(at: installer.binary.deletingLastPathComponent(), withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: installer.serviceFile.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("live".utf8).write(to: installer.binary)
    try Data("previous".utf8).write(to: installer.previous)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: installer.previous.path)
    try Data("existing service".utf8).write(to: installer.serviceFile)
    if action == "upgrade" {
      guard case let .machineV2Install(command) = try Command.parse(["machine-v2", "upgrade", installer.machine, "--binary", fixture.3.path]) else { Issue.record("upgrade did not select installer"); return }
      #expect(command == .upgrade(machine: installer.machine, binary: fixture.3.path))
    }
    try await withDependencies { $0.continuousClock = ImmediateClock() } operation: {
      switch action {
      case "upgrade": try await installer.upgrade(candidate: fixture.3)
      case "install-over-existing": try await installer.install(candidate: fixture.3)
      default: try await installer.rollback()
      }
    }
    #expect(try (Data(contentsOf: installer.serviceFile) == Data("existing service".utf8)) == (action != "install-over-existing"))
    let commands = launchctl.state.withLock { $0.commands.filter { !$0.last!.contains(".preflight") } }
    #expect(commands.map { $0[1] } == (action == "rollback-unloaded" ? ["bootout", "print", "bootstrap", "bootstrap", "bootstrap"] : ["bootout", "print", "print", "print", "bootstrap", "bootstrap", "bootstrap"]))
    #expect(commands.first?.last == "gui/501/" + installer.label)
    #expect(commands.last == ["/bin/launchctl", "bootstrap", "gui/501", installer.serviceFile.path])
    #expect(launchctl.state.withLock { $0.loaded })
    #expect(try Data(contentsOf: installer.binary) == Data((action.hasPrefix("rollback") ? "previous" : "new signed artifact").utf8))
  }

  @Test func unloadTimeoutIsBoundedAndNeverBootstraps() async throws {
    let launchctl = Launchctl()
    launchctl.state.withLock { $0.unloadingPrints = 200 }
    let helper = MachineV2Launchd(userID: 501, command: { try launchctl.run($0) })
    try await withDependencies { $0.continuousClock = ImmediateClock() } operation: {
      do { try await helper.bootout("gui/501/test"); Issue.record("unload timeout succeeded") }
      catch let error as MachineV2InstallError {
        #expect(error.code == .serviceFailure)
        #expect(error.message.contains("within 10 seconds"))
        #expect(error.message.contains("service is still loaded"))
        #expect(error.message.contains("launchctl print gui/501/test"))
      }
    }
    #expect(launchctl.state.withLock { $0.commands.count } == 101)
    #expect(launchctl.state.withLock { !$0.commands.contains { $0[1] == "bootstrap" } })
  }

  @Test(arguments: [false, true])
  func printFailureCannotBeMistakenForUnloaded(_ duringBootstrap: Bool) async throws {
    let launchctl = Launchctl()
    launchctl.state.withLock { $0.printFailure = 13; $0.bootstrapStatuses = [13] }
    let helper = MachineV2Launchd(userID: 501, command: { try launchctl.run($0) })
    do {
      if duringBootstrap { try await helper.bootstrap(label: "test", plist: URL(fileURLWithPath: "/private/service.plist")) }
      else { try await helper.bootout("gui/501/test") }
      Issue.record("print error was ignored")
    } catch let error as MachineV2InstallError {
      #expect(error.code == .serviceFailure)
      #expect(error.message.contains("service state is unknown"))
      #expect(!error.message.contains("service was left unloaded"))
    }
    #expect(launchctl.state.withLock { $0.commands.count } == 2)
  }

  @Test(arguments: [Int32(5), 13], [false, true])
  func exhaustedBootstrapReportsServiceStateAndExactRecovery(_ status: Int32, loaded: Bool) async throws {
    let launchctl = Launchctl()
    launchctl.state.withLock { $0.loaded = loaded; $0.bootstrapStatuses = Array(repeating: status, count: 5) }
    let helper = MachineV2Launchd(userID: 501, command: { try launchctl.run($0) })
    try await withDependencies { $0.continuousClock = ImmediateClock() } operation: {
      do { try await helper.bootstrap(label: "test", plist: URL(fileURLWithPath: "/private/owner's home/service.plist")); Issue.record("bootstrap failure was ignored") }
      catch let error as MachineV2InstallError {
        #expect(error.code == .serviceFailure)
        #expect(error.message.contains("after \(status == 5 ? 5 : 1) attempt(s)"))
        #expect(error.message.contains(loaded ? "service is still loaded" : "service was left unloaded"))
        #expect(error.message.contains("launchctl bootstrap gui/501 '/private/owner'\"'\"'s home/service.plist'"))
      }
    }
    #expect(launchctl.state.withLock { $0.commands.filter { $0[1] == "bootstrap" }.count } == (status == 5 ? 5 : 1))
  }
}
