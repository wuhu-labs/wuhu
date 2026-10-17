#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
#if canImport(Darwin)
  import Darwin
#else
  import Glibc
#endif

enum MachineV2InstallCommand: Equatable {
  case install(machine: String, binary: String)
  case upgrade(machine: String, binary: String)
  case rollback(machine: String)
  case uninstall(machine: String)

  var verb: String {
    switch self { case .install: "install"; case .upgrade: "upgrade"; case .rollback: "rollback"; case .uninstall: "uninstall" }
  }

  var machine: String {
    switch self {
    case let .install(machine, _), let .upgrade(machine, _), let .rollback(machine), let .uninstall(machine): machine
    }
  }
}

extension CommandRunner {
  func runMachineV2Install(_ action: MachineV2InstallCommand) async throws {
    guard let command = self.machineV2ServiceCommand else { throw CLIError(message: "machine-v2 installer has no service-manager executor") }
    guard let path = self.environment["HOME"], path.hasPrefix("/") else { throw CLIError(message: "machine-v2 installer requires absolute HOME") }
    let home = URL(fileURLWithPath: path)
    let installer = MachineV2Installer.local(home: home, machine: action.machine, environment: self.environment, command: command)
    switch action {
    case let .install(_, binary), let .upgrade(_, binary):
      let enrollment = try MachineV2Home.locate(environment: self.environment, machine: action.machine)
      _ = try enrollment.load()
      _ = try enrollment.loadKey()
      // Installing is the person putting this machine back on: a recorded leave no longer holds.
      try enrollment.clearLeft()
      let candidate = URL(fileURLWithPath: binary, relativeTo: URL(fileURLWithPath: self.currentDirectory)).standardizedFileURL
      guard case .upgrade = action else { try await installer.install(candidate: candidate); break }
      // Upgrade keeps the installed service definition as it is, hand edits included; only install writes one.
      do { try await installer.upgrade(candidate: candidate) }
      catch let error as MachineV2InstallError where error.code == .notInstalled {
        throw CLIError(message: "machine-v2 \(action.machine) is not installed: \(error.message)")
      }
    case .rollback: try await installer.rollback()
    case .uninstall:
      try await installer.uninstall {
        try await MachineV2Runtime.leaveForUninstall(home: MachineV2Home(root: home.appendingPathComponent(".wuhu/machine-v2"), machine: action.machine))
      }
    }
    await self.stdout("machine-v2 \(action.machine): service updated\n")
  }
}

func machineV2ServiceArguments(_ arguments: [String], platform: MachineV2Installer.Platform, environment: [String: String], userID: UInt32) -> [String] {
  guard platform == .linux else { return arguments }
  let configured = environment["XDG_RUNTIME_DIR"].flatMap { $0.isEmpty ? nil : $0 }
  return ["/usr/bin/env", "XDG_RUNTIME_DIR=\(configured ?? "/run/user/\(userID)")"] + arguments
}

func machineV2SessionRefusal(_ verb: String) -> String {
  let usage: String
  switch verb {
  case "install", "upgrade": usage = "\(verb) <id> --binary <signed-wuhu>"
  case "join": usage = "join <https-origin> [fingerprint] [--name <name-v2>] < v2-token"
  case "preflight": usage = "preflight <id> <private-result-path>"
  default: usage = "\(verb) <id>"
  }
  return "machine-v2 \(verb) is a person action, not a session action; run explicitly as the wallet owner: WUHU_IDENTITY=wallet wuhu machine-v2 \(usage)"
}
