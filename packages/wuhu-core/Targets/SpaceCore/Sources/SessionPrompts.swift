#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import GRDB
import SessionDomain
import struct SpaceContract.PromptSession
import struct SpaceContract.SessionPromptOutput
import StructuredQueries
import StructuredQueriesSQLite

// A session's prompt for its generation. The row moves to the current
// generation and revision at creation, after a template clone, at every
// compaction and at Start over, and clears the text; the first inference
// after renders the prompt at that revision and stores it, and every later
// inference of the generation sends the same bytes. A session with no row
// predates the table: it gets one on its next activation.
@Table("session_prompts")
struct SessionPromptRow {
  @Column("session_id", primaryKey: true) var sessionID: String
  @Column("generation") var generation: Int64
  @Column("rev") var rev: Int64
  @Column("prompt") var prompt: String?
  @Column("session") var session: String?
}

/// A prompt not rendered yet: the space's files are read at `rev`, and only
/// a rendering for this very generation and revision is stored.
public struct PendingPrompt: Equatable, Sendable {
  public let generation: Int
  public let rev: Int
}

public enum SessionPromptState: Equatable, Sendable {
  case pending(PendingPrompt)
  case rendered(SessionPromptOutput)
}

enum SessionPrompts {
  static func advance(_ key: String, in db: Database) throws {
    let rev = try Substrate.maxRevision(in: db)
    let generation = try Sessions.runtime(key, in: db).generation
    try SessionPromptRow.upsert { SessionPromptRow(sessionID: key, generation: generation, rev: rev, prompt: nil, session: nil) }.execute(db)
  }

  static func row(_ key: String, in db: Database) throws -> SessionPromptRow? {
    try SessionPromptRow.where { $0.sessionID.eq(key) }.fetchOne(db)
  }

  static func state(_ row: SessionPromptRow) throws -> SessionPromptState {
    guard let prompt = row.prompt, let session = row.session else {
      return .pending(PendingPrompt(generation: Int(row.generation), rev: Int(row.rev)))
    }
    return .rendered(SessionPromptOutput(prompt: prompt, session: try JSONDecoder().decode(PromptSession.self, from: Data(session.utf8))))
  }
}

extension SessionStore {
  /// The revision the session's prompt reads files at, or nil for a session
  /// that predates the table and has not been activated since.
  public func promptRevision(_ id: SessionID) async throws -> Int? {
    let key = id.rawValue
    return try await writer.read { db in
      _ = try Sessions.record(key, in: db)
      return try SessionPrompts.row(key, in: db).map { Int($0.rev) }
    }
  }

  /// The generation's prompt, or the revision it renders at; a session with
  /// no row gets one at the current revision.
  public func activatePrompt(_ id: SessionID) async throws -> SessionPromptState {
    let key = id.rawValue
    // Every kernel inference lands here: a stored row is a plain read, and a
    // write transaction opens only for a session that has none yet.
    if let row = try await writer.read({ db in
      _ = try Sessions.record(key, in: db)
      return try SessionPrompts.row(key, in: db)
    }) {
      return try SessionPrompts.state(row)
    }
    return try await writer.write { db in
      if let row = try SessionPrompts.row(key, in: db) { return try SessionPrompts.state(row) }
      try SessionPrompts.advance(key, in: db)
      return try SessionPrompts.state(SessionPrompts.row(key, in: db)!)
    }
  }

  /// Stores `rendered` as the prompt of `pending` and returns the
  /// generation's prompt: one already stored wins, and a rendering for a
  /// generation or revision that has since moved is returned unstored.
  public func storePrompt(_ id: SessionID, for pending: PendingPrompt, _ rendered: SessionPromptOutput) async throws -> SessionPromptOutput {
    let key = id.rawValue
    let session = String(decoding: try JSONEncoder().encode(rendered.session), as: UTF8.self)
    return try await writer.write { db in
      guard let row = try SessionPrompts.row(key, in: db),
            row.generation == Int64(pending.generation), row.rev == Int64(pending.rev)
      else { return rendered }
      if case let .rendered(stored) = try SessionPrompts.state(row) { return stored }
      try SessionPromptRow.where { $0.sessionID.eq(key) }
        .update { $0.prompt = #bind(rendered.prompt); $0.session = #bind(session) }
        .execute(db)
      return rendered
    }
  }

  func advancePromptRevision(_ id: SessionID) async throws {
    let key = id.rawValue
    try await writer.write { db in
      _ = try Sessions.record(key, in: db)
      try SessionPrompts.advance(key, in: db)
    }
  }
}
