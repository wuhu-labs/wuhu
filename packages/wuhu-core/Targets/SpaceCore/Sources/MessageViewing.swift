import GRDB
import struct SpaceContract.GroupID
import SpaceFS

let messageViewingSchemaSQL = """
CREATE TABLE IF NOT EXISTS "message_viewing" (
  "message_id" TEXT NOT NULL PRIMARY KEY,
  "path" TEXT NOT NULL
);
"""

/// The space path of the doc or page a person had open when sending. It is
/// stored group-qualified and handed to each reader as its own group names it.
public struct Viewing: Hashable, Sendable {
  public static let maxBytes = 1024

  public let group: GroupID
  public let path: SpacePath

  public init(group: GroupID, path: SpacePath) {
    self.group = group
    self.path = path
  }

  /// `spelling` as a sender acting in `group` names it: hostless in that
  /// group, or `wuhu://<group>.localspace/<path>`.
  public init(_ spelling: String, actingIn group: GroupID) throws(ViewingError) {
    guard spelling.utf8.count <= Self.maxBytes else { throw .tooLong(spelling.utf8.count) }
    guard !spelling.unicodeScalars.contains(where: Self.refuses) else { throw .forbiddenCharacter(spelling) }
    let named: (group: GroupID, path: String)?
    do { named = try GroupID.address(spelling) } catch { throw .notASpacePath(spelling) }
    guard let path = try? SpacePath(validating: named?.path ?? spelling) else { throw .notASpacePath(spelling) }
    self.init(group: named?.group ?? group, path: path)
  }

  /// Legal in a space path, but markup or a break in a header line.
  static func refuses(_ scalar: Unicode.Scalar) -> Bool {
    "<>&\"'".unicodeScalars.contains(scalar) || scalar.properties.isWhitespace || scalar.properties.generalCategory == .control
  }

  public var stored: String { group.address(path.rawValue) }

  public func named(for viewer: GroupID) -> String {
    viewer == group ? path.rawValue : stored
  }
}

public enum ViewingError: Error, Equatable, Sendable {
  case tooLong(Int)
  case notASpacePath(String)
  case forbiddenCharacter(String)
  case unreadable(String)

  public var message: String {
    switch self {
    case let .tooLong(bytes):
      "viewing is at most \(Viewing.maxBytes) bytes, got \(bytes)"
    case let .notASpacePath(spelling):
      "viewing \(spelling) must be a space path: /<path>, or wuhu://<group>.localspace/<path> for another group"
    case let .forbiddenCharacter(spelling):
      "viewing \(spelling) may not contain whitespace, control characters, quotes, <, > or &"
    case let .unreadable(spelling):
      "viewing \(spelling) is not a path you can read"
    }
  }
}

extension Viewing {
  static func stored(_ raw: String) -> Viewing {
    guard let address = try? GroupID.address(raw), let path = try? SpacePath(validating: address.path) else {
      preconditionFailure("message_viewing holds \(raw), not a group-qualified space path")
    }
    return Viewing(group: address.group, path: path)
  }

  static func insert(_ viewing: Viewing, message: String, in db: Database) throws {
    try db.execute(
      sql: "INSERT INTO message_viewing (message_id, path) VALUES (?, ?)",
      arguments: [message, viewing.stored],
    )
  }
}

extension Space {
  /// What a person acting as `principal` names in `viewing`, refused unless
  /// it reads that path right now. A missing path and an unreadable one are
  /// refused alike.
  public func viewing(_ spelling: String, as principal: Principal) async throws -> Viewing {
    let viewing = try Viewing(spelling, actingIn: principal.group)
    guard try await sessions.readsFile(viewing.path.rawValue, in: viewing.group, as: principal) else {
      throw ViewingError.unreadable(spelling)
    }
    do {
      _ = try await fs(viewing.group).stat(viewing.path.rawValue)
    } catch SpaceError.notFound {
      throw ViewingError.unreadable(spelling)
    }
    return viewing
  }
}
