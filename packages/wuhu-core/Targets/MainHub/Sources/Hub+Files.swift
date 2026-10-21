#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import struct MachineContract.MachineEntry
import struct MachineContract.MachineID
import enum MachineContract.VFSOp
import enum MachineContract.VFSResult
import SessionDomain

// What main still does to files itself: reading an attachment. The agent's
// file tools and images run in the worker over main's API.
extension Hub {
  nonisolated func machineStat(_ machine: MachineID, path: String) async throws -> MachineEntry? {
    switch try await machineVFS(machine, .stat(path: path)) {
    case let .entry(entry):
      return entry
    case let .error(error):
      guard error.code == .notFound else { throw ToolProblem(error.message) }
      return nil
    default:
      throw ToolProblem("machine returned an unexpected stat result for \(path)")
    }
  }

  /// The file whole when it is at most `limit` bytes, else `MachineSeam.OverLimit`.
  nonisolated func machineBytes(_ machine: MachineID, path: String, limit: Int) async throws -> [UInt8] {
    guard let machines else {
      throw ToolProblem("no machine backend is available on this server")
    }
    return try await machines.fileBytes(machine, path, limit: limit).bytes
  }

  nonisolated func machineVFS(_ machine: MachineID, _ op: VFSOp) async throws -> VFSResult {
    guard let machines else {
      throw ToolProblem("no machine backend is available on this server")
    }
    return try await machines.vfs(machine, op)
  }
}
