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
  case rollback(machine: String)
  case uninstall(machine: String)

  var verb: String {
    switch self { case .install: "install"; case .rollback: "rollback"; case .uninstall: "uninstall" }
  }

  var machine: String {
    switch self {
    case let .install(machine, _), let .rollback(machine), let .uninstall(machine): machine
    }
  }
}

extension CommandRunner {
  func runMachineV2Install(_ action: MachineV2InstallCommand) async throws {
    guard let command = self.machineV2ServiceCommand else { throw CLIError(message: "machine-v2 installer has no service-manager executor") }
    guard let path = self.environment["HOME"], path.hasPrefix("/") else { throw CLIError(message: "machine-v2 installer requires absolute HOME") }
    let home = URL(fileURLWithPath: path)
    #if os(macOS)
      let platform = MachineV2Installer.Platform.macOS
    #else
      let platform = MachineV2Installer.Platform.linux
    #endif
    let environment = self.environment
    let installer = MachineV2Installer(home: home, machine: action.machine, platform: platform, userID: getuid(), command: { arguments in
      try await command(machineV2ServiceArguments(arguments, platform: platform, environment: environment, userID: getuid()))
    })
    switch action {
    case let .install(_, binary):
      let enrollment = try MachineV2Home.locate(environment: self.environment, machine: action.machine)
      _ = try enrollment.load()
      _ = try enrollment.loadKey()
      let candidate = URL(fileURLWithPath: binary, relativeTo: URL(fileURLWithPath: self.currentDirectory)).standardizedFileURL
      try await installer.install(candidate: candidate)
    case .rollback: try await installer.rollback()
    case .uninstall:
      try await installer.uninstall {
        try await MachineV2Runtime.leave(home: MachineV2Home(root: home.appendingPathComponent(".wuhu/machine-v2"), machine: action.machine))
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
