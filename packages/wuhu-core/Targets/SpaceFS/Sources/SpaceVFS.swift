import struct Foundation.Data
import struct Foundation.Date

public struct Entry: Hashable, Sendable {
  public enum Kind: Hashable, Sendable {
    case file
    case directory
    case table
    case symlink
  }

  public var name: String
  public var kind: Kind
  public var size: Int
  public var lineCount: Int?
  public var token: VersionToken
  public var mtime: Date

  public init(
    name: String,
    kind: Kind,
    size: Int,
    lineCount: Int?,
    token: VersionToken,
    mtime: Date,
  ) {
    self.name = name
    self.kind = kind
    self.size = size
    self.lineCount = lineCount
    self.token = token
    self.mtime = mtime
  }
}

public protocol SpaceVFS: Sendable {
  func read(_ path: String) async throws -> (VersionToken, Data)
  /// The file at `path` as it is now, read a range at a time: a later write
  /// to `path` does not change what it reads.
  func reader(_ path: String) async throws -> any SpaceFileReader
  func write(_ path: String, _ data: Data, ifMatch: VersionToken?) async throws -> VersionToken
  func delete(_ path: String, ifMatch: VersionToken?) async throws
  func move(_ path: String, to destination: String) async throws
  func list(_ path: String) async throws -> (VersionToken, [Entry])
  /// At most `limit` children of `path` named `from` or later in UTF-8 byte order,
  /// and the name the following page starts at, nil when none remain.
  func list(_ path: String, from: String, limit: Int) async throws -> (entries: [Entry], next: String?)
  func stat(_ path: String) async throws -> Entry
}

public protocol SpaceFileReader: Sendable {
  /// At most `count` bytes from `offset`; fewer only at the end of the file.
  func read(at offset: Int, count: Int) async throws -> Data
}

/// A file already in memory.
public struct SpaceDataReader: SpaceFileReader {
  public let data: Data

  public init(_ data: Data) {
    self.data = data
  }

  public func read(at offset: Int, count: Int) async throws -> Data {
    guard offset < data.count else { return Data() }
    let start = data.startIndex + offset
    return Data(data[start ..< min(start + count, data.endIndex)])
  }
}

extension SpaceVFS {
  public func list(_ path: String, from: String, limit: Int) async throws -> (entries: [Entry], next: String?) {
    try await listBySlicing(path, from: from, limit: limit)
  }

  /// A page cut from the whole listing: what a backend that cannot seek does.
  public func listBySlicing(_ path: String, from: String, limit: Int) async throws -> (entries: [Entry], next: String?) {
    precondition(limit > 0)
    let entries = try await list(path).1
      .filter { !$0.name.utf8.lexicographicallyPrecedes(from.utf8) }
      .sorted { $0.name.utf8.lexicographicallyPrecedes($1.name.utf8) }
    return entries.count > limit ? (Array(entries.prefix(limit)), entries[limit].name) : (entries, nil)
  }
}
