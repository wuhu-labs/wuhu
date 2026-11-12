import Clocks
import Dependencies
import struct MainHub.ScriptHandlerResult
import func ServerTelemetry.expectingCache
import SessionDomain
import SessionTools
import SpaceCore
import Wuwei
#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif

/// What the session and observer cells and their jobs reach beyond their tables, registered on the worker where the loops are wired, so that everything runs under the same dependencies, clock and randomness.
struct LoopClient: Sendable {
  let space: Space
  let scripts: Scripts
  let tools: ToolExecutor
  let store: SessionStore
  let config: LoopConfig
  let sleep: @Sendable (Duration) -> @Sendable () async throws -> Void
  let dependencies: DependencyValues.Continuation
  let scheduler: any Scheduler
  /// Runs a handler firing's script, as its slot's owner.
  let handler: @Sendable (HandlerJob.Params) async throws -> ScriptHandlerResult

  func now() -> Date {
    Date(scheduler.now)
  }

  /// The middle of the current millisecond, to compare a due time with: a time whose wake has come has then passed, whatever a Double made of either.
  func dueNow() -> Date {
    Date(timeIntervalSince1970: (Double(scheduler.now.milliseconds) + 0.5) / 1000)
  }

  func uuid() -> UUID {
    dependencies.yield {
      @Dependency(\.uuid) var uuid
      return uuid()
    }
  }

  func jitter() -> Double {
    dependencies.yield {
      @Dependency(\.withRandomNumberGenerator) var withRandomNumberGenerator
      return withRandomNumberGenerator { Double.random(in: 0 ... 1, using: &$0) }
    }
  }

  func lines(_ session: SessionID, _ generation: Int) async throws -> [TranscriptLine] {
    try await store.transcriptLines(session, generation: generation).map { try $0.line() }
  }

  func attempt(_ request: InferenceRequest) async throws -> InferenceReply {
    let cache = request.lines.cacheExpectation(now: now())
    return try await dependencies.yield { try await expectingCache(cache) { try await config.inference(request) } }
  }

  /// The step's fullness when it is past the hard threshold, or past the soft one with no pressure notice pending.
  func overThreshold(_ step: InferenceJob.Params) async throws -> Double? {
    let lines = try await lines(step.session, step.generation)
    let fullness = await fullness(lines, step.session)
    if fullness >= config.thresholds.hard { return fullness }
    if fullness >= config.thresholds.soft, !lines.hasPendingPressureNotice { return fullness }
    return nil
  }

  func budget(_ session: SessionID) async -> ContextBudget {
    await dependencies.yield { await config.budget(session) }
  }

  func fullness(_ lines: [TranscriptLine], _ session: SessionID) async -> Double {
    lines.contextFullness(budget: await budget(session))
  }

  func execute(_ invocation: ToolInvocation) async throws -> ToolOutcome {
    try await dependencies.yield { try await config.executeTool(invocation) }
  }

  func kill(_ invocation: ToolInvocation) async {
    await dependencies.yield { await config.killInterruptedTool(invocation) }
  }

  func runningWork(_ session: SessionID) async throws -> [String] {
    try await dependencies.yield { try await config.runningWork(session) }
  }

  func prepareCompaction(_ session: SessionID, _ tokenEstimate: Int, _ target: CompactionTarget?) async throws -> ModelRouteTransition? {
    try await dependencies.yield { try await config.prepareCompaction(session, tokenEstimate, target) }
  }
}

extension Date {
  init(_ instant: Instant) {
    self.init(timeIntervalSince1970: Double(instant.milliseconds) / 1000)
  }
}

func deadlineSleep(after delay: Duration, clock: any NonsendingClock<Duration>) -> @Sendable () async throws -> Void {
  let clock = AnyClock(clock)
  let deadline = clock.now.advanced(by: delay)
  return { try await clock.sleep(until: deadline, tolerance: nil) }
}
