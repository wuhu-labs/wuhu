#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import Subprocess

/// Runs `command[0]` with the rest as arguments and returns its whole standard output; a nonzero exit is a ``CommandFailure`` carrying trimmed standard error.
public func capturedProcessOutput(_ command: [String]) async throws -> String {
  let result = try await Subprocess.run(.path(.init(command[0])), arguments: Arguments(Array(command.dropFirst())), output: .string(limit: .max), error: .string(limit: .max))
  switch result.terminationStatus {
  case .exited(0): return result.standardOutput ?? ""
  case let .exited(status), let .signaled(status):
    throw CommandFailure(command: command, status: status, stderr: (result.standardError ?? "").trimmingCharacters(in: .whitespacesAndNewlines))
  }
}
