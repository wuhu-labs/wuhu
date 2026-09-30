#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import struct SessionDomain.SessionID
import StructuredQueries
import StructuredQueriesSQLite

let inferenceSchemaSQL = """
CREATE TABLE IF NOT EXISTS "inferences" (
  "id" TEXT NOT NULL PRIMARY KEY,
  "session" TEXT NOT NULL,
  "at" TEXT NOT NULL,
  "provider" TEXT NOT NULL,
  "model" TEXT NOT NULL,
  "served_model" TEXT,
  "effort" TEXT NOT NULL,
  "input" INTEGER,
  "cache_read" INTEGER,
  "cache_write" INTEGER,
  "output" INTEGER,
  "reasoning" INTEGER,
  "outcome" TEXT NOT NULL,
  "error" TEXT,
  "duration_ms" INTEGER,
  "ttft_ms" INTEGER,
  "grp" TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS "inferences_by_session_at" ON "inferences" ("session", "at");
CREATE INDEX IF NOT EXISTS "inferences_by_grp_at" ON "inferences" ("grp", "at");
"""

public struct InferenceRecord: Sendable {
  public let id: String
  public let session: SessionID
  public let at: Date
  public let provider: String
  public let model: String
  public let servedModel: String?
  public let effort: String
  public let input: Int?
  public let cacheRead: Int?
  public let cacheWrite: Int?
  public let output: Int?
  public let reasoning: Int?
  public let outcome: String
  public let error: String?
  public let durationMs: Int64?
  public let ttftMs: Int64?

  public init(
    id: String,
    session: SessionID,
    at: Date,
    provider: String,
    model: String,
    servedModel: String? = nil,
    effort: String,
    input: Int? = nil,
    cacheRead: Int? = nil,
    cacheWrite: Int? = nil,
    output: Int? = nil,
    reasoning: Int? = nil,
    outcome: String,
    error: String? = nil,
    durationMs: Int64? = nil,
    ttftMs: Int64? = nil,
  ) {
    self.id = id
    self.session = session
    self.at = at
    self.provider = provider
    self.model = model
    self.servedModel = servedModel
    self.effort = effort
    self.input = input
    self.cacheRead = cacheRead
    self.cacheWrite = cacheWrite
    self.output = output
    self.reasoning = reasoning
    self.outcome = outcome
    self.error = error
    self.durationMs = durationMs
    self.ttftMs = ttftMs
  }
}

@Table("inferences")
struct InferenceRow {
  @Column("id", primaryKey: true) var id: String
  @Column("session") var session: String
  @Column("at") var at: String
  @Column("provider") var provider: String
  @Column("model") var model: String
  @Column("served_model") var servedModel: String?
  @Column("effort") var effort: String
  @Column("input") var input: Int?
  @Column("cache_read") var cacheRead: Int?
  @Column("cache_write") var cacheWrite: Int?
  @Column("output") var output: Int?
  @Column("reasoning") var reasoning: Int?
  @Column("outcome") var outcome: String
  @Column("error") var error: String?
  @Column("duration_ms") var durationMs: Int64?
  @Column("ttft_ms") var ttftMs: Int64?
  @Column("grp") var grp: String
}

extension Space {
  public func recordInference(_ inference: InferenceRecord) async throws {
    try await writer.write { db in
      let session = try Sessions.record(inference.session.rawValue, in: db)
      try InferenceRow.insert {
        InferenceRow(
          id: inference.id,
          session: inference.session.rawValue,
          at: SQLiteDateFormat.string(from: inference.at),
          provider: inference.provider,
          model: inference.model,
          servedModel: inference.servedModel,
          effort: inference.effort,
          input: inference.input,
          cacheRead: inference.cacheRead,
          cacheWrite: inference.cacheWrite,
          output: inference.output,
          reasoning: inference.reasoning,
          outcome: inference.outcome,
          error: inference.error,
          durationMs: inference.durationMs,
          ttftMs: inference.ttftMs,
          grp: session.group.rawValue,
        )
      }.execute(db)
    }
  }
}
