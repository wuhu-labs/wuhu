#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import func MainHub.runningJSON
import func MainHub.seconds
import SessionDomain
import SessionTools
import StructuredQueries
import struct WuhuAI.ToolCall
import Wuwei
import WuweiQueries

@Job
struct ScriptJob {
  static let schema = [
    "CREATE TABLE script_runs (\(ownerColumn), phase TEXT NOT NULL, wait_until REAL NOT NULL, lifetime_until REAL NOT NULL, yield_by REAL, answered INTEGER NOT NULL, resulted INTEGER NOT NULL, stop TEXT, kill_at REAL, posts INTEGER NOT NULL, UNIQUE (owner))",
  ]

  struct Params: Codable {
    let session: SessionID
    let handle: String
    let slot: ToolCallJob.ID
    let call: ToolCall
    let plan: ScriptPlan
    let yieldBy: Date?
  }

  enum Message: Codable {
    case output(ScriptRuntime.Event)
    case cancel
    case interrupt
    case yield(by: Date)
  }

  static func create(ctx: inout JobContext<Self>) throws {
    let params = ctx.params
    let now = Date(ctx.now)
    let row = ScriptRow(waitUntil: now.addingTimeInterval(params.plan.wait), lifetimeUntil: now.addingTimeInterval(params.plan.lifetime), yieldBy: params.yieldBy)
    try ctx.db.execute(ScriptRow.insert { row })
  }

  mutating func start() async throws -> Outcome {
    let row = db.rows(ScriptRow.all).first!
    if row.phase == "ended" { return .done }
    if row.phase == "running" { return try restarted() }
    precondition(row.phase == "ready")
    try db.execute(ScriptRow.update { $0.phase = "running" })
    let client = ctx.dependency(LoopClient.self)
    let params = ctx.params
    let worker = client.space.worker
    let address = id
    let runtime = client.scripts.runtime(id: String(params.handle.dropFirst("script.".count)), session: params.session, plan: params.plan, tools: client.tools) { event in
      worker.send(.output(event), to: address)
    }
    let effects = ctx.effects
    async let evaluation: Void = effects.effect { await client.dependencies.yield { await runtime.run() } }
    do {
      while true {
        let row = db.rows(ScriptRow.all).first!
        let now = Date(ctx.now)
        if let killAt = row.killAt, killAt <= now {
          runtime.kill()
          try await evaluation
          try db.execute(ScriptRow.update { $0.killAt = #bind(Optional<Date>.none) })
          continue
        } else if row.stop == nil, row.lifetimeUntil <= now {
          try stop("lifetime", runtime: runtime)
          continue
        } else if !row.answered, row.stop == nil, min(row.waitUntil, row.yieldBy ?? .distantFuture) <= now {
          let arrival = (row.yieldBy ?? .distantFuture) <= row.waitUntil
          let after = arrival ? "a message arrived, so the call gave the turn back before result()" : "no result() within \(seconds(.seconds(params.plan.wait))) s"
          let note = "\(after); it keeps running, its result arrives as a message, and cancel(\"\(params.handle)\") stops it"
          answer(.result(.script(.init(output: runningJSON(params.handle, tail: runtime.consoleTail, note: note))), context: nil))
          try db.execute(ScriptRow.update { $0.answered = true })
          continue
        }
        let deadline = row.killAt ?? (row.stop == nil ? min(row.lifetimeUntil, row.answered ? .distantFuture : min(row.waitUntil, row.yieldBy ?? .distantFuture)) : .distantFuture)
        let delay = max(0.001, min(3600, deadline.timeIntervalSince(Date(ctx.now))))
        guard let message = try await ctx.receive(within: .seconds(delay)) else { continue }
        switch message {
        case .cancel: if row.stop == nil { try stop("cancel", runtime: runtime) }
        case .interrupt: if row.stop == nil { try stop("interrupt", runtime: runtime) }
        case let .yield(by):
          let by = min(row.yieldBy ?? .distantFuture, by)
          try db.execute(ScriptRow.update { $0.yieldBy = #bind(by) })
        case let .output(.result(text)):
          precondition(!row.resulted)
          if row.answered { post("result of \(params.handle):\n" + text) }
          else {
            let note = "\n\n[\(params.handle): any update() after this arrives as a message; cancel(\"\(params.handle)\") ends it while it runs.]"
            answer(.result(.script(.init(output: text + note)), context: nil))
          }
          try db.execute(ScriptRow.update { $0.answered = true; $0.resulted = true })
        case let .output(.update(text)):
          precondition(row.resulted)
          post(text)
          try db.execute(ScriptRow.update { $0.posts += 1 })
        case let .output(.ended(ending)):
          try await evaluation
          if !row.answered {
            answer(row.stop == "interrupt" ? .interrupted : .result(.failure(.init(message: ending.beforeResult)), context: nil))
          } else if row.stop != "cancel", row.stop != "interrupt" {
            if !row.resulted { post(ending.beforeResult) }
            else if let failure = ending.afterResult { post(failure) }
          }
          return try ended()
        }
      }
    } catch is CancellationError {
      runtime.kill()
      _ = try? await evaluation
      return try restarted()
    }
  }

  private mutating func stop(_ reason: String, runtime: ScriptRuntime) throws {
    let killAt = Date(ctx.now).addingTimeInterval(5)
    try db.execute(ScriptRow.update { $0.stop = #bind(reason); $0.killAt = #bind(killAt) })
    runtime.abort(lifetime: reason == "lifetime")
  }

  private mutating func restarted() throws -> Outcome {
    if db.rows(ScriptRow.all).first!.answered { post("\(ctx.params.handle) ended because the server restarted; its script was not rerun") }
    else { answer(.serverRestarted) }
    return try ended()
  }

  private mutating func ended() throws -> Outcome {
    ctx.send(SessionCell.ID(ctx.params.session.rawValue)).scriptEnded(id)
    try db.execute(ScriptRow.update { $0.phase = "ended"; $0.answered = true })
    return .done
  }

  private mutating func answer(_ answer: ToolCallAnswer) {
    ctx.send(SessionCell.ID(ctx.params.session.rawValue)).scriptAnswered(ctx.params.slot, answer)
  }

  private mutating func post(_ text: String) {
    ctx.send(SessionCell.ID(ctx.params.session.rawValue)).scriptPosted(ctx.params.handle, text)
  }
}

@Table("script_runs")
struct ScriptRow: Owned {
  var phase = "ready"
  @Column("wait_until") let waitUntil: Date
  @Column("lifetime_until") let lifetimeUntil: Date
  @Column("yield_by") var yieldBy: Date?
  var answered = false
  var resulted = false
  var stop: String?
  @Column("kill_at") var killAt: Date?
  var posts = 0
}
