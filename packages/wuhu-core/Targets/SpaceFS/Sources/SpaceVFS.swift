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
  func write(_ path: String, _ data: Data, ifMatch: VersionToken?) async throws -> VersionToken
  func delete(_ path: String, ifMatch: VersionToken?) async throws
  func move(_ path: String, to destination: String) async throws
  func list(_ path: String) async throws -> (VersionToken, [Entry])
  func stat(_ path: String) async throws -> Entry
}
