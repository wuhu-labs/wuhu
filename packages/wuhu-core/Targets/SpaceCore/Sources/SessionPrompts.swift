#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import struct SessionDomain.TranscriptPreamble
import struct SpaceContract.PromptSession
import StructuredQueries
import Wuwei
import WuweiQueries

@Table("session_prompts")
struct SessionPromptRow {
  @Column("session_id", primaryKey: true) var sessionID: String
  @Column("generation") var generation: Int64
  @Column("revs") var revs: String
  @Column("rendered") var rendered: String?
  @Column("session") var session: String?
}

/// A generation's prompt as stored: the blob `/_/rendered/<rendered>` holds `preamble`, what every request of the generation sends besides its messages, and `opening` is the text of its first user-role messages, ahead of the transcript's.
public struct StoredPrompt: Equatable, Sendable {
  public let rendered: String
  public let preamble: TranscriptPreamble
  public let opening: [String]
  public let session: PromptSession

  public init(rendered: String, preamble: TranscriptPreamble, opening: [String], session: PromptSession) {
    self.rendered = rendered
    self.preamble = preamble
    self.opening = opening
    self.session = session
  }
}

/// What follows the system text, split from it by who changes it: the group's instructions, then the session's own. An empty one has no line.
public struct PromptOpening: Equatable, Sendable, Codable {
  public let group: String
  public let session: String

  public init(group: String, session: String) {
    self.group = group
    self.session = session
  }
}

/// A prompt not rendered yet: the groups' files are read at `revs`, and only
/// a rendering for this very generation and revision is stored. `opening` is
/// whether the generation's lines keep room for one; without it the whole
/// prompt is the system text.
public struct PendingPrompt: Equatable, Sendable, Codable {
  public let generation: Int
  public let revs: [String: Int]
  public let opening: Bool
}

public enum SessionPromptState: Equatable, Sendable {
  case pending(PendingPrompt)
  case rendered(StoredPrompt)
}

public enum SessionPromptReference: Sendable {
  case pending(PendingPrompt)
  case rendered(hash: String, opening: [String], session: PromptSession)
}

public enum SessionPrompts {
  public static func revisions(_ key: String, in db: Wuwei.Database) throws -> [String: Int]? {
    _ = try generation(key, in: db)
    return try row(key, in: db).map { try Sessions.decode([String: Int].self, from: $0.revs) }
  }

  public static func reference(_ key: String, in db: Wuwei.Database) throws -> SessionPromptReference? {
    _ = try generation(key, in: db)
    return try row(key, in: db).map { try reference($0, in: db) }
  }

  public static func invalidate(_ key: String, in db: inout Wuwei.Database) throws {
    _ = try generation(key, in: db)
    try db.execute(SessionPromptRow.where { $0.sessionID.eq(key) }.delete())
  }

  public static func pending(_ key: String, revs: [String: Int], in db: Wuwei.Database) throws -> PendingPrompt {
    let query = PromptRuntimeRow.where { $0.sessionID.eq(key) }.select { runtime in
      PendingPromptRead.Columns(
        generation: runtime.generation,
        opening: #sql("""
        COALESCE((
          SELECT position = \(bind: Int64(Sessions.openingKeys.count + 1)) FROM session_lines
          WHERE session_id = \(runtime.sessionID) AND generation = \(runtime.generation) AND position > 0
            AND key NOT IN (\(bind: Sessions.openingKeys[0]), \(bind: Sessions.openingKeys[1]))
          ORDER BY position LIMIT 1
        ), NOT EXISTS (
          SELECT 1 FROM session_pointers WHERE session_id = \(runtime.sessionID) AND generation = \(runtime.generation)
        ))
        """, as: Bool.self),
      )
    }
    guard let row = db.rows(query).first else { throw SessionStoreError.unknownSession(key) }
    return PendingPrompt(generation: Int(row.generation), revs: revs, opening: row.opening)
  }

  public static func setIfAbsent(_ key: String, pending: PendingPrompt, in db: inout Wuwei.Database) throws {
    guard try generation(key, in: db) == Int64(pending.generation) else { return }
    let row = SessionPromptRow(sessionID: key, generation: Int64(pending.generation), revs: try Sessions.encode(pending.revs), rendered: nil, session: nil)
    try db.execute(SessionPromptRow.insert { row } onConflict: { $0.sessionID })
  }

  public static func winner(_ key: String, for pending: PendingPrompt, in db: Wuwei.Database) throws -> SessionPromptReference? {
    guard let row = row(key, in: db), row.generation == Int64(pending.generation), try Sessions.decode([String: Int].self, from: row.revs) == pending.revs, row.rendered != nil else { return nil }
    return try reference(row, in: db)
  }

  public static func store(
    _ key: String, for pending: PendingPrompt, rendered: String, opening: PromptOpening?, session: PromptSession, at: Date, in db: inout Wuwei.Database,
  ) throws {
    precondition(opening == nil || pending.opening, "the generation keeps no room for an opening")
    guard let row = row(key, in: db), row.generation == Int64(pending.generation), try Sessions.decode([String: Int].self, from: row.revs) == pending.revs, row.rendered == nil else { return }
    let encoded = try Sessions.encode(session)
    try db.execute(SessionPromptRow.where { $0.sessionID.eq(key) }.update { $0.rendered = #bind(rendered); $0.session = #bind(encoded) })
    try writePreamble(key, generation: row.generation, rendered: rendered, opening: opening, at: at, in: &db)
  }

  private static func row(_ key: String, in db: Wuwei.Database) -> SessionPromptRow? {
    db.rows(SessionPromptRow.where { $0.sessionID.eq(key) }).first
  }

  private static func generation(_ key: String, in db: Wuwei.Database) throws -> Int64 {
    guard let generation = db.rows(PromptRuntimeRow.where { $0.sessionID.eq(key) }.select(\.generation)).first else {
      throw SessionStoreError.unknownSession(key)
    }
    return generation
  }

  private static func reference(_ row: SessionPromptRow, in db: Wuwei.Database) throws -> SessionPromptReference {
    switch (row.rendered, row.session) {
    case (nil, nil):
      return .pending(PendingPrompt(generation: Int(row.generation), revs: try Sessions.decode([String: Int].self, from: row.revs), opening: keepsOpening(row.sessionID, generation: row.generation, in: db)))
    case let (rendered?, session?):
      return .rendered(
        hash: rendered, opening: try opening(row.sessionID, generation: row.generation, in: db),
        session: try Sessions.decode(PromptSession.self, from: session),
      )
    default:
      preconditionFailure("a rendered prompt stores both its blob and session")
    }
  }
}

@Table("session_runtime")
private struct PromptRuntimeRow {
  @Column("session_id", primaryKey: true) var sessionID: String
  var generation: Int64
}

@Selection
private struct PendingPromptRead {
  let generation: Int64
  let opening: Bool
}
