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
    let installer = MachineV2Installer(home: home, machine: action.machine, platform: platform, userID: getuid(), command: command)
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
