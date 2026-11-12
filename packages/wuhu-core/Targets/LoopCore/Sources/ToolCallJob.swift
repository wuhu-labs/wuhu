import SessionDomain
import SessionTools
import SpaceCore
import StructuredQueries
import struct WuhuAI.ToolCall
import Wuwei
import WuweiQueries
#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif

/// Exec resumes its committed wait; repeatable file calls discard uncommitted output and restart their whole effect.
@Job
struct ToolCallJob {
  static let schema = [
    "CREATE TABLE tool_calls (\(ownerColumn), started INTEGER NOT NULL, answer TEXT, UNIQUE (owner))",
    "ALTER TABLE tool_calls ADD COLUMN exec TEXT",
  ]

  struct Params: Codable {
    let session: SessionID
    let generation: Int
    let position: Int
    let call: ToolCall
    /// When input already waited as the call started.
    let yieldBy: Date?
  }

  enum Message: Codable {
    case finished(ExecFinished)
    case interrupt
    case yield(by: Date)
  }

  static func create(ctx: inout JobContext<Self>) throws {
    try ctx.db.execute(CallRow.insert { CallRow() })
  }

  mutating func start() async throws -> Outcome {
    guard let row = db.rows(CallRow.all).first else { return .done }
    if let answer = row.answer { return send(answer) }
    let client = ctx.dependency(LoopClient.self)
    let params = ctx.params
    if params.call.name == "exec" {
      let state = try ctx.cell(SessionCell.ID(params.session.rawValue)).shown()
      return try await exec(state: state, saved: row.exec)
    }
    let repeatable = switch params.call.name {
    case "read", "find", "grep": true
    default: false
    }
    let mutation = switch params.call.name {
    case "write", "edit": true
    default: false
    }
    let lost: ToolCallAnswer = mutation ? .result(.failure(.init(
      message: "outcomeUnknown: \(params.call.name) ended without its result and was not repeated: read the path to see whether it applied before retrying",
      code: "unavailable",
    )), context: nil) : .serverRestarted
    if row.started, !repeatable { return try answer(lost) }
    try db.execute(CallRow.update { $0.started = true })
    let state = try ctx.cell(SessionCell.ID(params.session.rawValue)).shown()
    let deadline = YieldDeadline(params.yieldBy)
    do {
      let raced = try await ctx.race({ _, messages in
        let invocation = ToolInvocation(sessionID: params.session, call: params.call, state: state, yielded: { await deadline.passed(client) })
        return try await deadline.collecting(messages, { $0.yieldBy }) {
          do { return try await client.execute(invocation) }
          catch is CancellationError { throw CancellationError() }
          catch { return ToolOutcome(payload: .failure(.init(message: String(describing: error)))) }
        }
      }, until: { if case .interrupt = $0 { true } else { false } })
      switch raced {
      case let .finished(outcome):
        if repeatable || mutation, Task.isCancelled {
          if !mutation { return .notDone }
          if case .failure = outcome.payload { return .notDone }
        }
        return try answer(.result(outcome.payload, context: outcome.context))
      case .message:
        let invocation = ToolInvocation(sessionID: params.session, call: params.call, state: state)
        try await ctx.effect { await client.kill(invocation) }
        return try answer(.interrupted)
      }
    } catch is CancellationError {
      if repeatable || mutation, Task.isCancelled { return .notDone }
      return try answer(lost)
    }
  }

  mutating func answer(_ answer: ToolCallAnswer) throws -> Outcome {
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
  case serverRestarted
}

@Table("tool_calls")
struct CallRow: Owned {
  var started = false
  @Column(as: ToolCallAnswer?.JSONRepresentation.self) var answer: ToolCallAnswer?
  @Column(as: ToolExecTarget?.JSONRepresentation.self) var exec: ToolExecTarget?
}
