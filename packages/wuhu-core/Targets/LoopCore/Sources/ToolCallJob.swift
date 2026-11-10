import SessionDomain
import StructuredQueries
import struct WuhuAI.ToolCall
import WuweiNeo
import WuweiNeoQueries
#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif

/// One tool call as a job: the call at `position` of generation `generation`, run once, its answer sent to its session cell. It reads the transcript its id names for the tool state. A start that finds the call already started answers `interrupted`: a call never runs twice. `interrupt` kills it; an exec or a script answers `running` once the deadline of its `yield(by:)` mail, or of its params, has passed.
@Job
struct ToolCallJob {
  static let schema = [
    "CREATE TABLE tool_calls (\(ownerColumn), started INTEGER NOT NULL, answer TEXT, UNIQUE (owner))",
  ]

  struct Params: Codable {
    let session: SessionID
    let generation: Int
    let position: Int
    let call: ToolCall
    /// When input already waited as the call started.
    let yieldBy: Date?
  }

  enum Message: Codable, Equatable {
    case interrupt
    case yield(by: Date)
  }

  static func create(ctx: inout JobContext<Self>) throws {
    try ctx.db.execute(CallRow.insert { CallRow() })
  }

  mutating func start() async throws -> Outcome {
    guard let row = db.rows(CallRow.all).first else { return .done }
    if let answer = row.answer { return send(answer) }
    if row.started { return try answer(.interrupted) }
    try db.execute(CallRow.update { $0.started = true })
    let client = ctx.dependency(LoopClient.self)
    let params = ctx.params
    let state = try await ctx.effect { try await client.transcript(params.session, params.generation, params.position) }.environment.tools
    let deadline = YieldDeadline(params.yieldBy)
    let raced = try await ctx.race({ _, messages in
      let invocation = ToolInvocation(sessionID: params.session, call: params.call, state: state, yielded: { await deadline.passed(client) })
      return try await deadline.collecting(messages, { $0.yieldBy }) {
        do { return try await client.execute(invocation) }
        catch is CancellationError { throw CancellationError() }
        catch { return ToolOutcome(payload: .failure(.init(message: String(describing: error)))) }
      }
    }, until: { $0 == .interrupt })
    switch raced {
    case let .finished(outcome):
      return try answer(.result(outcome.payload, context: outcome.context))
    case .message:
      let invocation = ToolInvocation(sessionID: params.session, call: params.call, state: state)
      try await ctx.effect { await client.kill(invocation) }
      return try answer(.interrupted)
    }
  }

  private mutating func answer(_ answer: ToolCallAnswer) throws -> Outcome {
    try db.execute(CallRow.update { $0.answer = #bind(answer) })
    return send(answer)
  }

  private func send(_ answer: ToolCallAnswer) -> Outcome {
    .done(sending: .called(id, answer), to: SessionCell.ID(ctx.params.session.rawValue).recipient)
  }
}

extension ToolCallJob.Message {
  var yieldBy: Date? {
    if case let .yield(by) = self { by } else { nil }
  }
}

/// How a tool call ended, as the session cell writes it.
enum ToolCallAnswer: Sendable, Codable {
  case result(ToolResultPayload, context: ScopeContext?)
  case interrupted
}

@Table("tool_calls")
struct CallRow: Owned {
  var started = false
  @Column(as: ToolCallAnswer?.JSONRepresentation.self) var answer: ToolCallAnswer?
}
