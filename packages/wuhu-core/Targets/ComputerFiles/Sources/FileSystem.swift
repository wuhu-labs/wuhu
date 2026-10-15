#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif

public struct ComputerFileStatus: Sendable, Equatable {
  public let version: String
  public let size: UInt64
  public let kind: String
  public init(version: String, size: UInt64, kind: String) { self.version = version; self.size = size; self.kind = kind }
}

public struct ComputerFile: Sendable {
  public let status: @Sendable () async throws -> ComputerFileStatus
  public let read: @Sendable (UInt64, Int) async throws -> Data
  public init(status: @escaping @Sendable () async throws -> ComputerFileStatus, read: @escaping @Sendable (UInt64, Int) async throws -> Data) { self.status = status; self.read = read }
}

public struct ComputerEntry: Sendable {
  public let path: String
  public let kind: String
  public let file: ComputerFile?
  public init(path: String, kind: String, file: ComputerFile? = nil) { self.path = path; self.kind = kind; self.file = file }
}

public struct ComputerWalk: Sendable {
  private let advance: @Sendable (@escaping @Sendable () async throws -> Void) async throws -> ComputerEntry?
  public let close: @Sendable () async -> Void
  public let skipCounts: @Sendable () async -> [String: Int]
  public init(next: @escaping @Sendable () async throws -> ComputerEntry?, close: @escaping @Sendable () async -> Void, skipCounts: @escaping @Sendable () async -> [String: Int] = { [:] }) { advance = { check in try await check(); return try await next() }; self.close = close; self.skipCounts = skipCounts }
  init(checkedNext: @escaping @Sendable (@escaping @Sendable () async throws -> Void) async throws -> ComputerEntry?, close: @escaping @Sendable () async -> Void, skipCounts: @escaping @Sendable () async -> [String: Int]) { advance = checkedNext; self.close = close; self.skipCounts = skipCounts }
  public func next(check: @escaping @Sendable () async throws -> Void = { try Task.checkCancellation() }) async throws -> ComputerEntry? { try await advance(check) }
}

/// Streaming companion to VirtualFileSystem: that contract's children/readData materialize whole directories/files.
public struct ComputerFileSystem: Sendable {
  public let status: @Sendable (String) async throws -> ComputerFileStatus
  public let read: @Sendable (String, UInt64, Int) async throws -> Data
  public let operations: ComputerFileOperations
  public let walk: @Sendable (String, Bool) async throws -> ComputerWalk
  public init(status: @escaping @Sendable (String) async throws -> ComputerFileStatus, read: @escaping @Sendable (String, UInt64, Int) async throws -> Data, walk: @escaping @Sendable (String, Bool) async throws -> ComputerWalk, operations: ComputerFileOperations = .unsupported) { self.status = status; self.read = read; self.walk = walk; self.operations = operations }
}
