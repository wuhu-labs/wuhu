#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import struct MachineContract.MachineEntry
import struct OperationProtocol.OperationError

public struct ComputerDirectory: Sendable {
  public let next: @Sendable () async throws -> MachineEntry?
  public let close: @Sendable () async -> Void
  public init(next: @escaping @Sendable () async throws -> MachineEntry?, close: @escaping @Sendable () async -> Void) { self.next = next; self.close = close }
}

public struct ComputerWriter: Sendable {
  public let append: @Sendable (Data) async throws -> Void
  public let prepare: @Sendable () async throws -> Void
  public let commit: @Sendable () async throws -> String
  public let close: @Sendable () async -> Void
  public init(append: @escaping @Sendable (Data) async throws -> Void, prepare: @escaping @Sendable () async throws -> Void = {}, commit: @escaping @Sendable () async throws -> String, close: @escaping @Sendable () async -> Void) { self.append = append; self.prepare = prepare; self.commit = commit; self.close = close }
}

public struct ComputerFileOperations: Sendable {
  public let stat: @Sendable (String) async throws -> MachineEntry
  public let list: @Sendable (String) async throws -> ComputerDirectory
  public let write: @Sendable (String, String?) async throws -> ComputerWriter
  public let mkdir: @Sendable (String) async throws -> Void
  public let remove: @Sendable (String, String?) async throws -> Void
  public let move: @Sendable (String, String) async throws -> Void
  public init(stat: @escaping @Sendable (String) async throws -> MachineEntry, list: @escaping @Sendable (String) async throws -> ComputerDirectory, write: @escaping @Sendable (String, String?) async throws -> ComputerWriter, mkdir: @escaping @Sendable (String) async throws -> Void, remove: @escaping @Sendable (String, String?) async throws -> Void, move: @escaping @Sendable (String, String) async throws -> Void) { self.stat = stat; self.list = list; self.write = write; self.mkdir = mkdir; self.remove = remove; self.move = move }
  public static var unsupported: Self { .init(stat: { _ in throw OperationError(.kindFailed) }, list: { _ in throw OperationError(.kindFailed) }, write: { _, _ in throw OperationError(.kindFailed) }, mkdir: { _ in throw OperationError(.kindFailed) }, remove: { _, _ in throw OperationError(.kindFailed) }, move: { _, _ in throw OperationError(.kindFailed) }) }
}
