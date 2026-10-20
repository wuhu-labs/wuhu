import Contract
import JSONValue

@Contract
public struct ReadInput: Codable, Equatable, Sendable {
  public let path: String
  public let rev: Int?
  public let lines: String?
  /// Answer an image path with its stored bytes (`ReadOutput.image`) instead
  /// of refusing binary content.
  public let image: Bool?
}

@Contract
public struct ReadOutput: Codable, Equatable, Sendable {
  public let token: String
  /// An image's content is a line describing it; its bytes are in `image`.
  public let content: String
  public let image: ReadImageOutput?
}

/// An image the read tool stored: the content-addressed blob main keeps the
/// bytes in, their checked type and, when the header tells, the pixel size.
@Contract
public struct ReadImageOutput: Codable, Equatable, Sendable {
  public let mimeType: String
  public let blob: String
  public let byteCount: Int
  public let width: Int?
  public let height: Int?
}

@Contract
public struct WriteInput: Codable, Equatable, Sendable {
  public let path: String
  public let content: String
  public let ifMatch: String?
  /// Refuse to replace an existing file (`conflict`); a creation with no
  /// version to match.
  public let createOnly: Bool?
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
  /// Refuse a directory with more entries than this.
  public let limit: Int?
  /// Refuse a listing whose rendered form exceeds this many bytes.
  public let byteLimit: Int?
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
  /// An ICU regular expression, matched against each line.
  public let pattern: String
  public let path: String?
  /// Most matches in a page: default 50, capped at 1000.
  public let matchLimit: Int?
  /// Search hidden entries too (dot-names, and `/_` and `/users` at a space root).
  public let hidden: Bool?
  /// Search what `.gitignore` files exclude too.
  public let noIgnore: Bool?
  public let step: String?
}

@Contract
public struct GrepOutput: Codable, Equatable, Sendable {
  public let matches: [Match]
  /// Present iff the page stopped early; pass it back as `step`.
  public let cursor: String?
  /// Entries this page visited.
  public let scanned: Int
  /// What the walk passed over, one row per reason.
  public let skipped: [SearchSkipped]
}

/// Why a search passed an entry over.
@Contract
public enum SearchSkipReason: String, Codable, Equatable, Sendable {
  case hidden
  /// Excluded by a `.gitignore`.
  case ignored
  case binary
  /// A file with a line over 64 KiB; the rest of it is not read.
  case longLine
  case unreadable
}

/// Entries a search passed over for one reason: how many, and the first.
@Contract
public struct SearchSkipped: Codable, Equatable, Sendable {
  public let reason: SearchSkipReason
  public let count: Int
  public let example: String
}

@Contract
public struct FindInput: Codable, Equatable, Sendable {
  /// A glob in the `.gitignore` dialect, matched against paths relative to `path`.
  public let glob: String
  public let path: String?
  /// Most paths in a page: default 50, capped at 1000.
  public let matchLimit: Int?
  public let hidden: Bool?
  public let noIgnore: Bool?
  public let step: String?
}

@Contract
public struct FindOutput: Codable, Equatable, Sendable {
  public let paths: [String]
  public let cursor: String?
  public let scanned: Int
  public let skipped: [SearchSkipped]
}
