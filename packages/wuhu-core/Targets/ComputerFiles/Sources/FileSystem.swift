#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import protocol FileSearch.SearchSource

public struct ComputerFileStatus: Sendable, Equatable {
  public let version: String
  public let size: UInt64
  public let kind: String
  public init(version: String, size: UInt64, kind: String) { self.version = version; self.size = size; self.kind = kind }
}

/// Streaming companion to VirtualFileSystem: that contract's children/readData materialize whole directories/files.
public struct ComputerFileSystem: Sendable {
  public let status: @Sendable (String) async throws -> ComputerFileStatus
  public let read: @Sendable (String, UInt64, Int) async throws -> Data
  public let operations: ComputerFileOperations
  /// What `search.v1` walks, for one query's root.
  public let search: @Sendable (String) -> any SearchSource
  /// Disk effects whose caller stopped waiting that have not ended yet; each holds a receipt of the machine's admission budget.
  public let abandonedEffects: @Sendable () -> Int
  public init(status: @escaping @Sendable (String) async throws -> ComputerFileStatus, read: @escaping @Sendable (String, UInt64, Int) async throws -> Data, search: @escaping @Sendable (String) -> any SearchSource, abandonedEffects: @escaping @Sendable () -> Int = { 0 }, operations: ComputerFileOperations = .unsupported) { self.status = status; self.read = read; self.search = search; self.abandonedEffects = abandonedEffects; self.operations = operations }
}
