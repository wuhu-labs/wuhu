import Contract
import JSONValue

@Contract
public struct ReadInput: Codable, Equatable, Sendable {
  public let path: String
  public let rev: Int?
  public let lines: String?
}

@Contract
public struct ReadOutput: Codable, Equatable, Sendable {
  public let token: String
  public let content: String
}

@Contract
public struct WriteInput: Codable, Equatable, Sendable {
  public let path: String
  public let content: String
  public let ifMatch: String?
}

@Contract
public struct WriteOutput: Codable, Equatable, Sendable {
  public let rev: Int?
  public let token: String
}

@Contract
public struct EditInput: Codable, Equatable, Sendable {
  public let path: String
  public let edits: [EditOp]
  public let ifMatch: String?
}

@Contract
public struct EditOutput: Codable, Equatable, Sendable {
  public let rev: Int?
  public let token: String
}

@Contract
public struct SyncInput: Codable, Equatable, Sendable {
  public let path: String
  public let baseToken: String
  public let content: String
}

@Contract
public enum SyncOutput: Codable, Equatable, Sendable {
  case saved(rev: Int, token: String, content: String)
  case merged(rev: Int, token: String, content: String)
  case conflict(token: String, content: String)
}

@Contract
public struct RemoveInput: Codable, Equatable, Sendable {
  public let path: String
  public let ifMatch: String?
}

@Contract
public struct MoveInput: Codable, Equatable, Sendable {
  public let from: String
  public let to: String
  public let replace: Bool?
}

@Contract
public struct MoveOutput: Codable, Equatable, Sendable {
  public let rev: Int?
  public let dangling: [String]
}

@Contract
public struct ListInput: Codable, Equatable, Sendable {
  public let path: String
  public let rev: Int?
  public let hidden: Bool?
}

@Contract
public struct ListOutput: Codable, Equatable, Sendable {
  public let rev: Int?
  public let entries: [Entry]
}

@Contract
public struct StatInput: Codable, Equatable, Sendable {
  public let path: String
}

@Contract
public struct GrepInput: Codable, Equatable, Sendable {
  public let pattern: String
  public let path: String?
  public let matchLimit: Int?
  public let entryLimit: Int?
  public let step: String?
}

@Contract
public struct GrepOutput: Codable, Equatable, Sendable {
  public let matches: [Match]
  public let cursor: String?
}

@Contract
public struct FindInput: Codable, Equatable, Sendable {
  public let glob: String
  public let path: String?
  public let matchLimit: Int?
  public let entryLimit: Int?
  public let step: String?
}

@Contract
public struct FindOutput: Codable, Equatable, Sendable {
  public let paths: [String]
  public let cursor: String?
}
