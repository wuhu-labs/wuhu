#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import struct SessionDomain.SessionID
import struct SpaceContract.GroupID
import StructuredQueries
import StructuredQueriesSQLite

public struct InferenceRecord: Sendable {
  /// Who an attempt is billed to.
  public enum Payer: Sendable {
    case session(SessionID)
    /// A group observer's handler, in one firing.
    case observer(group: GroupID, firing: String)
  }

  public let id: String
  public let payer: Payer
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
    payer: Payer,
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
    self.payer = payer
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
  @Column("session") var session: String?
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
  @Column("firing") var firing: String?
}

extension Space {
  public func recordInference(_ inference: InferenceRecord) async throws {
    try await writer.write { db in
      let (session, group, firing): (String?, GroupID, String?) = switch inference.payer {
      case let .session(session): (session.rawValue, try Sessions.record(session.rawValue, in: db).group, nil)
      case let .observer(group, firing): (nil, group, firing)
      }
      try InferenceRow.insert {
        InferenceRow(
          id: inference.id,
          session: session,
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
          grp: group.rawValue,
          firing: firing,
        )
      } onConflict: { $0.id }.execute(db)
    }
  }
}
