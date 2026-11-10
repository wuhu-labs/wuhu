import Dependencies
import Logging
import struct ServerTelemetry.CacheExpectation
import SessionDomain
import StructuredQueries
import Wuwei
import WuweiQueries
#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
#if canImport(Darwin)
  import Darwin
#else
  import Glibc
#endif
import enum WuhuAI.InferenceError

/// How an inference step ended, as the session cell handles it, and what it took.
struct StepResult: Sendable, Codable {
  enum Ending: Sendable, Codable {
    /// `fullness` is the transcript's with the reply.
    case reply(AssistantEntry, fullness: Double)
    /// Interrupted, or yielded to waiting input or a compact command while it waited.
    case cancelled
    /// The transcript is past a compaction threshold: no attempt was made.
    case full(Double)
    case compact(CompactCause)
    case requestTooLarge(limitBytes: Int?, failure: String)
    case handoff(ReplayBinding, ContextBudget)
    case parked(String)
  }

  enum CompactCause: String, Sendable, Codable {
    case forced
    case contextTooLong
  }

  var ending: Ending
  var attempts: Int
  var waitedMs: Int
}

@Table("inference_attempts")
struct AttemptRow: Owned {
  let id: String
  var failure: String?
}

/// One step as a job: it owns its attempts, each with a fresh id that the wire shows, the waits between them and their records, and keeps its outcome, so a restart never pays for a reply twice. It reads the transcript its id names (generation, first `position` items) before every attempt, and answers its session cell. A normal step first checks the compaction thresholds. `interrupt` ends it at once; a wait between attempts ends at the earliest `yield(by:)` it was mailed, an attempt never.
@Job
struct InferenceJob {
  static let schema = [
    """
    CREATE TABLE inference_steps (\(ownerColumn), attempts INTEGER NOT NULL, backoff_attempt INTEGER NOT NULL, idle_timeouts INTEGER NOT NULL,
      bounded_failures INTEGER NOT NULL, waited_ms INTEGER NOT NULL, retry_at REAL, outcome TEXT, UNIQUE (owner))
    """,
    "CREATE TABLE inference_attempts (id TEXT PRIMARY KEY, \(ownerColumn), failure TEXT)",
  ]

  struct Params: Codable {
    let session: SessionID
    let generation: Int
    let position: Int
    let mode: InferenceMode
  }

  enum Message: Codable, Equatable {
    case interrupt
    case yield(by: Date)

    var yieldBy: Date? {
      if case let .yield(by) = self { by } else { nil }
    }
  }

  static func create(ctx: inout JobContext<Self>) throws {
    try ctx.db.execute(Step.insert { Step() })
  }

  mutating func start() async throws -> Outcome {
    guard var retry = db.rows(Step.all).first else { return .done }
    if let outcome = retry.outcome { return answer(outcome) }
    let client = ctx.dependency(LoopClient.self)
    let params = ctx.params
    if params.mode == .normal, retry.attempts == 0, let fullness = try await ctx.effect({ try await client.overThreshold(params) }) {
      return try finish(.full(fullness), retry)
    }
    let deadline = YieldDeadline(nil)
    while true {
      if let retryAt = retry.retryAt {
        let remaining = retryAt.timeIntervalSince(client.now())
        if remaining > 0 {
          let sleep = client.sleep(.seconds(remaining))
          let waited = try await ctx.race({ _, messages in
            try await deadline.collecting(messages, { $0.yieldBy }) {
              try await withThrowingTaskGroup(of: Bool.self) { group in
                group.addTask {
                  try await sleep()
                  return false
                }
                group.addTask { await deadline.passed(client) }
                defer { group.cancelAll() }
                return try await group.next()!
              }
            }
          }, until: { $0 == .interrupt })
          guard case .finished(false) = waited else { return try finish(.cancelled, retry) }
        }
        retry.retryAt = nil
        try save(retry)
      }
      let transcript = try await ctx.effect { try await client.transcript(params.session, params.generation, params.position) }
      let attemptID = client.uuid()
      retry.attempts += 1
      try save(retry)
      let request = InferenceRequest(sessionID: params.session, attemptID: attemptID, generation: params.generation, transcript: transcript, mode: params.mode, idleTimeout: retry.idleTimeout)
      let raced = try await ctx.race({ _, messages in
        try await deadline.collecting(messages, { $0.yieldBy }) {
          do { return Result<InferenceReply, any Error>.success(try await client.attempt(request)) }
          catch { return .failure(error) }
        }
      }, until: { $0 == .interrupt })
      guard case let .finished(result) = raced else { return try finish(.cancelled, retry) }
      switch result {
      case let .success(reply):
        try db.execute(AttemptRow.insert { AttemptRow(id: attemptID.uuidString.lowercased(), failure: nil) })
        // Told before its session cell writes the reply.
        let (replied, entry) = client.dependencies.yield {
          var replied = transcript
          let entry = replied.appendAssistant(reply.message, id: attemptID, metadata: reply.metadata, replayBinding: reply.replayBinding)
          return (replied, entry)
        }
        let fullness = try await ctx.effect {
          await reply.committed(entry, replied)
          return await client.fullness(replied, params.session)
        }
        return try finish(.reply(entry, fullness: fullness), retry)
      case let .failure(error):
        // A draining worker cancels its jobs: that is no outcome, the step goes on where it is hosted next.
        try Task.checkCancellation()
        try db.execute(AttemptRow.insert { AttemptRow(id: attemptID.uuidString.lowercased(), failure: String(describing: error)) })
        switch retry.failed(error, mode: params.mode, session: params.session, now: client.now(), jitter: client.jitter) {
        case let .end(ending):
          return try finish(ending, retry)
        case let .wait(seconds):
          retry.waitedMs += Int((seconds * 1000).rounded())
          retry.retryAt = client.now().addingTimeInterval(seconds)
          try save(retry)
        }
      }
    }
  }

  /// `nil` while the step runs, and for a step never created.
  func outcome() -> StepResult? {
    db.rows(Step.all).first?.outcome
  }

  private mutating func save(_ retry: Step) throws {
    try db.execute(Step.update {
      $0.attempts = #bind(retry.attempts)
      $0.backoffAttempt = #bind(retry.backoffAttempt)
      $0.idleTimeouts = #bind(retry.idleTimeouts)
      $0.boundedFailures = #bind(retry.boundedFailures)
      $0.waitedMs = #bind(retry.waitedMs)
      $0.retryAtSeconds = #bind(retry.retryAtSeconds)
    })
  }

  private mutating func finish(_ ending: StepResult.Ending, _ retry: Step) throws -> Outcome {
    let outcome = StepResult(ending: ending, attempts: retry.attempts, waitedMs: retry.waitedMs)
    try db.execute(Step.update { $0.outcome = #bind(outcome) })
    return answer(outcome)
  }

  private func answer(_ outcome: StepResult) -> Outcome {
    .done(sending: .stepped(id, outcome), to: SessionCell.ID(ctx.params.session.rawValue).recipient)
  }
}

/// A step's row: where it stands between attempts, so a restarted step goes on counting and waits out the wait it chose, jitter included, and its outcome once it has one.
@Table("inference_steps")
struct Step: Owned {
  var attempts = 0
  @Column("backoff_attempt") var backoffAttempt = 0
  @Column("idle_timeouts") var idleTimeouts = 0
  @Column("bounded_failures") var boundedFailures = 0
  @Column("waited_ms") var waitedMs = 0
  /// Since the reference date, which round-trips a `Date` exactly.
  @Column("retry_at") var retryAtSeconds: Double?
  @Column(as: StepResult?.JSONRepresentation.self) var outcome: StepResult?

  var retryAt: Date? {
    get { retryAtSeconds.map(Date.init(timeIntervalSinceReferenceDate:)) }
    set { retryAtSeconds = newValue?.timeIntervalSinceReferenceDate }
  }

  enum Next {
    case wait(seconds: Double)
    case end(StepResult.Ending)
  }

  var idleTimeout: Duration {
    idleTimeoutSchedule[idleTimeouts]
  }

  mutating func failed(_ error: any Error, mode: InferenceMode, session: SessionID, now: Date, jitter: () -> Double) -> Next {
    if let boundary = error as? ReplayBoundaryRequired { return .end(.handoff(boundary.binding, boundary.budget)) }
    // A compaction during a quota wait folds mechanically, so placement can
    // move the next generation to a member with room.
    if mode == .forcedCompact, waitsOnQuota(error) { return .end(.compact(.forced)) }
    if let waiting = error as? ModelRouteWaiting { return .wait(seconds: delay(attempt: 1, until: waiting.retryAt, now: now, jitter: jitter)) }
    switch classify(error) {
    case let .outage(retryAt):
      idleTimeouts = 0
      boundedFailures = 0
      backoffAttempt += 1
      return .wait(seconds: delay(attempt: backoffAttempt, until: retryAt, now: now, jitter: jitter))
    case let .transient(timedOut):
      if timedOut {
        idleTimeouts += 1
        if idleTimeouts == idleTimeoutSchedule.count {
          Logger(label: "wuhu.loop").notice("inference parked after consecutive idle timeouts", metadata: ["session": "\(session.rawValue)", "consecutive_timeouts": "\(idleTimeouts)"])
          return .end(park(error, mode: mode))
        }
      } else {
        idleTimeouts = 0
      }
      boundedFailures += 1
      if boundedFailures == boundedFailureLimit {
        Logger(label: "wuhu.loop").notice("inference parked after consecutive unretryable failures", metadata: ["session": "\(session.rawValue)", "failures": "\(boundedFailures)", "error": "\(error)"])
        return .end(park(error, mode: mode))
      }
    case let .requestTooLarge(normalized):
      let limit: Int? = if case let .requestTooLarge(limit) = normalized { limit } else { nil }
      return .end(.requestTooLarge(limitBytes: limit, failure: String(describing: normalized)))
    case .contextTooLong:
      return .end(.compact(.contextTooLong))
    case .terminal:
      return .end(park(error, mode: mode))
    }
    backoffAttempt += 1
    return .wait(seconds: delay(attempt: backoffAttempt, now: now, jitter: jitter))
  }

  private func park(_ error: any Error, mode: InferenceMode) -> StepResult.Ending {
    mode == .forcedCompact ? .compact(.forced) : .parked(String(describing: error))
  }

  private func delay(attempt: Int, until retryAt: Date? = nil, now: Date, jitter: () -> Double) -> Double {
    if let wait = retryAt.map({ $0.timeIntervalSince(now) }), wait > 0 { return min(retryAtCeiling, wait) }
    return min(backoffCeiling, pow(2.0, Double(attempt - 1))) * jitter()
  }
}

// A silent >window phase re-burns the full prompt on every retry, so idle
// timeouts escalate 120s -> 300s -> 900s and park after the third in a row;
// any other outcome resets the escalation.
private let idleTimeoutSchedule: [Duration] = [.seconds(120), .seconds(300), .seconds(900)]

// A provider outage outlives any attempt count worth writing down: an unattended
// session that gives up after a minute needs a human at 3am to say "try again",
// which is the one thing the loop exists to avoid. Outages are bounded by rate,
// not by attempts — the backoff settles into a slow poll and waits.
let backoffCeiling: Double = 300

// A provider's own reset time replaces the exponential step, but no single
// header may stall a session for more than an hour: a weekly limit is re-asked
// hourly rather than trusted for days.
let retryAtCeiling: Double = 3600

// Everything retryable that is not obviously self-healing: a 5xx that never
// clears, a stream this build cannot parse, a token endpoint answering 400.
// Those do not get better by waiting, so they report instead of spinning.
let boundedFailureLimit = 8

enum FailureClass {
  case outage(retryAt: Date?)
  case transient(timedOut: Bool)
  case contextTooLong
  case requestTooLarge(InferenceError)
  case terminal
}

// Normalized, never downcast: the inference seam admits any error, and the
// hops before the model stream (catalog resolution, credential refresh) carry
// their own vocabularies. A downcast reads every one of them as terminal.
func classify(_ error: any Error) -> FailureClass {
  let normalized = InferenceError.normalize(error)
  return switch normalized {
  // An interrupt reaches a step as mail; a cancellation from upstream is a failure like any other.
  case .cancelled: .transient(timedOut: false)
  // Throttling and an unreachable network are the two failures that state
  // outright they are about right now rather than about the request.
  case .rateLimited(let retryAt): .outage(retryAt: retryAt)
  // Only a silent model stream escalates the idle-timeout schedule: it is the
  // one transport failure that re-burned the prompt to learn nothing.
  case .transport(.idleTimeout): .transient(timedOut: true)
  case .transport, .upstreamUnreachable: .outage(retryAt: nil)
  case .streamCut, .transient, .upstreamUnavailable: .transient(timedOut: false)
  case .contextTooLong: .contextTooLong
  case .requestTooLarge, .capacityExceeded: .requestTooLarge(normalized)
  case .requestTooLargeAfterCompaction, .malformedModelMessage, .oidcSigningFailed, .credentialRefreshRefused, .authenticationRefused, .invalidInput, .other: .terminal
  }
}

private func waitsOnQuota(_ error: any Error) -> Bool {
  if error is ModelRouteWaiting { return true }
  if case .rateLimited = InferenceError.normalize(error) { return true }
  return false
}

extension Transcript {
  /// What this generation's last reply predicts for the next prompt's cache: its whole prompt, idle since it came.
  func cacheExpectation(now: Date) -> CacheExpectation? {
    for item in items[keptCount...].reversed() {
      guard case let .assistant(entry) = item else { continue }
      return CacheExpectation(tokens: entry.usage.inputTokens, idleMs: max(0, Int((now.timeIntervalSince(entry.timestamp) * 1000).rounded())))
    }
    return nil
  }
}
