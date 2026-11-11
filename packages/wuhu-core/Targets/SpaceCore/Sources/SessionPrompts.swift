#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import GRDB
import SessionDomain
import struct SpaceContract.PromptSession
import StructuredQueries
import StructuredQueriesSQLite
import enum WuhuAI.Tool

// A session's prompt for its generation. The row moves to the current
// generation and revision at creation, after a template clone, at every
// compaction and at Start over, and clears the rendering; the first inference
// after renders the prompt at that revision and stores it, and every later
// inference of the generation sends the same bytes: the system text and the
// tool list, one content-addressed blob the row names by hash. A session with
// no row predates the table: it gets one on its next activation.
@Table("session_prompts")
struct SessionPromptRow {
  @Column("session_id", primaryKey: true) var sessionID: String
  @Column("generation") var generation: Int64
  @Column("rev") var rev: Int64
  @Column("rendered") var rendered: String?
  @Column("session") var session: String?
}

/// A generation's prompt as stored: the blob `/_/rendered/<rendered>` holds `preamble`, what every request of the generation sends besides its messages.
public struct StoredPrompt: Equatable, Sendable {
  public let rendered: String
  public let preamble: TranscriptPreamble
  public let session: PromptSession
}

/// A prompt not rendered yet: the space's files are read at `rev`, and only
/// a rendering for this very generation and revision is stored.
public struct PendingPrompt: Equatable, Sendable {
  public let generation: Int
  public let rev: Int
}

public enum SessionPromptState: Equatable, Sendable {
  case pending(PendingPrompt)
  case rendered(StoredPrompt)
}

enum SessionPrompts {
  static func advance(_ key: String, in db: Database) throws {
    let rev = try Substrate.maxRevision(in: db)
    let generation = try Sessions.runtime(key, in: db).generation
    try SessionPromptRow.upsert { SessionPromptRow(sessionID: key, generation: generation, rev: rev, rendered: nil, session: nil) }.execute(db)
  }

  static func row(_ key: String, in db: Database) throws -> SessionPromptRow? {
    try SessionPromptRow.where { $0.sessionID.eq(key) }.fetchOne(db)
  }

  static func state(_ row: SessionPromptRow, in db: Database, _ blobs: BlobCache) throws -> SessionPromptState {
    guard let rendered = row.rendered, let session = row.session else {
      return .pending(PendingPrompt(generation: Int(row.generation), rev: Int(row.rev)))
    }
    return .rendered(StoredPrompt(
      rendered: rendered, preamble: try JSONDecoder().decode(TranscriptPreamble.self, from: Data(try blobs.blob(of: rendered, in: db).content)),
      session: try JSONDecoder().decode(PromptSession.self, from: Data(session.utf8)),
    ))
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
    if let state = try await blobs.read(writer, { db, blobs in
      _ = try Sessions.record(key, in: db)
      return try SessionPrompts.row(key, in: db).map { try SessionPrompts.state($0, in: db, blobs) }
    }) {
      return state
    }
    return try await blobs.write(writer) { db, blobs in
      if let row = try SessionPrompts.row(key, in: db) { return try SessionPrompts.state(row, in: db, blobs) }
      try SessionPrompts.advance(key, in: db)
      return try SessionPrompts.state(SessionPrompts.row(key, in: db)!, in: db, blobs)
    }
  }

  /// Stores `prompt` and `tools` as the prompt of `pending` and returns the
  /// generation's prompt: one already stored wins, and a rendering for a
  /// generation or revision that has since moved is returned unstored. A
  /// stored one is the generation's line 0, by reference.
  public func storePrompt(_ id: SessionID, for pending: PendingPrompt, _ prompt: String, tools: [Tool], session: PromptSession) async throws -> StoredPrompt {
    let key = id.rawValue
    let preamble = TranscriptPreamble(system: prompt, tools: tools)
    let blob = try await blobs.stage(Array(try Sessions.encode(preamble).utf8))
    let rendered = StoredPrompt(rendered: blob.hash, preamble: preamble, session: session)
    let encoded = String(decoding: try JSONEncoder().encode(session), as: UTF8.self)
    let now = dateGen.now
    return try await blobs.write(writer) { db, blobs in
      guard let row = try SessionPrompts.row(key, in: db),
            row.generation == Int64(pending.generation), row.rev == Int64(pending.rev)
      else { return rendered }
      if case let .rendered(stored) = try SessionPrompts.state(row, in: db, blobs) { return stored }
      try Substrate.record(blob, in: db)
      try SessionPromptRow.where { $0.sessionID.eq(key) }
        .update { $0.rendered = #bind(blob.hash); $0.session = #bind(encoded) }
        .execute(db)
      try Sessions.writePreamble(key, generation: row.generation, rendered: blob.hash, at: now, in: db)
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
