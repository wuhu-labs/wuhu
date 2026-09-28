import Contract
import JSONValue

@Contract
public enum EntryKind: String, Codable, Equatable, Sendable {
  case file
  case directory
  case table
  case symlink
}

@Contract
public struct Entry: Codable, Equatable, Sendable {
  public let name: String
  public let kind: EntryKind
  public let size: Int
  public let lineCount: Int?
  public let token: String
  public let mtime: Double
}

@Contract
public struct EditOp: Codable, Equatable, Sendable {
  public let old: String
  public let new: String
}

@Contract
public struct Match: Codable, Equatable, Sendable {
  public let path: String
  public let line: Int
  public let text: String
  public let context: [String]
}

@Contract
public struct RevisionOutput: Codable, Equatable, Sendable {
  public let rev: Int
}
