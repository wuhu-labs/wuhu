import Dependencies
import enum Fetch.TransportFailureKind
import func MainHub.deadlineSleep
import ServerTelemetry
import TaskLifetime
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
import Logging
import SessionDomain
import SpaceCore
import struct WuhuAI.AssistantMessage
import enum WuhuAI.ContentBlock
import enum WuhuAI.InferenceError
import struct WuhuAI.ToolCall

extension SessionActor {
  // A forced compaction can start from a settled turn, so the transcript
  // alone would show no run; the row is told, and every exit re-derives it.
  // Run state is advisory: failing to write it never stops the compaction.
  func runForcedCompaction() async throws {
    try? await main.append(id, .compactionActivity(.active)).value(Void.self)
    do {
      try await runInference(mode: .forcedCompact)
    } catch {
      await settleCompacting()
      throw error
    }
    await settleCompacting()
  }

  private func settleCompacting() async {
    let main = main
    // Persist the settled state even when the loop was cancelled.
    await uncancellable("Persist settled compaction state after loop cancellation") { try? await main.append(id, .compactionActivity(.inactive)).value(Void.self) }
  }

  // The operator-facing compact verb, the kernel's counterpart to Claude
  // Code's `/compact` command: instructions land as one system
  // notification, and the turn that follows is tool-choice-pinned to compact.
  func takeCompactRequest() async throws -> Bool {
    guard !(try live).revoking else { return false }
    guard try await main.pendingCommand(id) != nil else { return false }
    try Task.checkCancellation()
    guard !(try live).revoking else { return false }
    let mountID = try live.mountID
    try modify { $0.claimingCompactRequest = true }
    defer {
      if liveState?.mountID == mountID { liveState?.claimingCompactRequest = false }
    }
    guard let claim = try await main.claimCompactRequest(id, generation: (try live).generation) else { return false }
    try modify {
      $0.transcript = claim.transcript
      $0.compactRequestClaim = claim
    }
    return true
  }

  // Only a model that stopped is asked whether it may; a generation that never
  // ran (created, restarted) is inert. What is left is a park wake.
  func idleNag() async throws -> Nag? {
    guard case .assistant? = (try live).transcript.items.last else { return nil }
    return try await nagOrScheduleWake((try live).transcript.environment)
  }

  func reconcileSubscriptions() async throws -> Bool {
    let registered = try await main.registeredSubscriptions(id)
    try Task.checkCancellation()
    guard !(try live).revoking else { return false }
    try modify {
      $0.transcript.registeredSubscriptions = registered.ids
      $0.transcript.handlerSubscriptions = registered.handlers
    }
    return true
  }

  // Cancelling the looper (retirement, shutdown) must cancel the work and must
  // never surface a late success: a cancelled pass may not touch actor state.
  func runLongRunningTask<T: Sendable>(body: @Sendable @escaping () async throws -> T) async -> Result<T, any Error> {
    guard !Task.isCancelled else { return .failure(CancellationError()) }
    assert(longRunningTask == nil)
    let workID = UUID()
    defer {
      if longRunningTask?.id == workID { longRunningTask = nil }
    }
    guard let work = try? taskScope.run("session-work", operation: { () -> Result<T, any Error> in
      do {
        return .success(try await body())
      } catch {
        return .failure(error)
      }
    }) else { return .failure(TaskScopeClosed()) }
    guard let handle = try? taskScope.run("session-work-cancellation", operation: {
      await withTaskCancellationHandler {
        _ = await work.value
      } onCancel: {
        work.cancel()
      }
    }) else { work.cancel(); return .failure(TaskScopeClosed()) }
    longRunningTask = (workID, handle)
    let result = await withTaskCancellationHandler {
      await work.value
    } onCancel: {
      handle.cancel()
    }
    guard !Task.isCancelled else { return .failure(CancellationError()) }
    return result
  }

  func markErrored(error: any Error) async {
    do {
      let errorDescription = String(describing: error)
      try modify { $0.sessionStatus = .errored(errorDescription) }
      try await main.append(id, .errored(errorDescription)).value(Void.self)
    } catch is CancellationError {
    } catch {
      Logger(label: "wuhu.loop").error("could not persist session error", metadata: ["session": "\(id.rawValue)", "error": "\(error)"])
    }
  }
}

private let interruptedToolMessage = """
Tool execution was interrupted by the user. It may have partially run; \
it will not be retried automatically.
"""

extension SessionActor {
  private enum ToolDispatchResult: Sendable {
    case completed(ToolResultPayload?), cancelled
  }

  func execute(_ toolCall: ToolCall) async throws {
    try await traced(.tool) { span in
      span.set(.tool, toolCall.name)
      span.set(.toolCallID, toolCall.id)
      span.set(.bytesIn, toolCall.arguments.text.utf8.count)
      switch try await executeBody(toolCall) {
      case let .completed(payload):
        span.record(payload)
      case .cancelled:
        span.conclude(.cancelled)
      }
    }
  }

  private func executeBody(_ toolCall: ToolCall) async throws -> ToolDispatchResult {
    switch KernelTool(rawValue: toolCall.name) {
    case .bookmark:
      return try await .completed(executeBookmark(toolCall))
    case .compact:
      return try await .completed(executeCompact(toolCall))
    case nil:
      break
    }

    let invocation = ToolInvocation(
      sessionID: id,
      call: toolCall,
      state: (try live).transcript.environment.tools,
    )
    inFlightTool = invocation
    let result = await runLongRunningTask { [loopConfig] in
      try await loopConfig.executeTool(invocation)
    }
    inFlightTool = nil

    let callID = ToolCallID(toolCall.id)
    switch result {
    case .success(let outcome):
      let written = try await writeToolResult(.toolCall(callID), outcome.payload, context: outcome.context)
      await outcome.committed?()
      return .completed(written)
    case .failure(is CancellationError):
      guard !Task.isCancelled else { return .cancelled }
      // Released by a hand-off: the call stays pending for the next worker.
      if (try live).revoking { return .cancelled }
      if case .interrupting = (try live).sessionStatus {
        await loopConfig.killInterruptedTool(invocation)
        try await writeToolResult(.toolCall(callID), .failure(.init(message: interruptedToolMessage)))
      }
      return .cancelled
    case .failure(let error):
      return try await .completed(writeToolResult(.toolCall(callID), .failure(.init(message: String(describing: error)))))
    }
  }

  private func executeBookmark(_ toolCall: ToolCall) async throws -> ToolResultPayload? {
    let arguments: BookmarkArguments
    do {
      arguments = try decodeArguments(BookmarkArguments.self, from: toolCall)
    } catch {
      let payload = ToolResultPayload.failure(.init(message: "invalid bookmark arguments: \(error)"))
      try await writeToolResult(.toolCall(.init(toolCall.id)), payload)
      return payload
    }
    let marker = BookmarkMarker(
      id: uuid(),
      timestamp: date(),
      name: arguments.name,
      toolCallID: .init(toolCall.id),
    )
    try await appended([.bookmark(marker)])
    return nil
  }

  private func executeCompact(_ toolCall: ToolCall) async throws -> ToolResultPayload {
    let callID = ToolCallID(toolCall.id)
    let arguments: CompactArguments
    do {
      arguments = try decodeArguments(CompactArguments.self, from: toolCall)
    } catch {
      let payload = ToolResultPayload.failure(.init(message: "invalid compact arguments: \(error)"))
      try await writeToolResult(.toolCall(callID), payload)
      return payload
    }
    return try await traced(.compaction) { span in
      span.set(.compactionReason, .tool)
      span.set(.generation, liveState?.generation)
      let payload = try await fold(callID, arguments, span: span)
      if case .failure = payload { span.conclude(.errored) } else { span.conclude(.ok) }
      return payload
    }
  }

  private func fold(_ callID: ToolCallID, _ arguments: CompactArguments, span: TelemetrySpan<StepOutcome>) async throws -> ToolResultPayload {
    let transcript = (try live).transcript
    let kept: Range<Int>?
    do {
      kept = try transcript.compactKeptRange(callID: callID, bookmark: arguments.bookmark)
    } catch let notFound as BookmarkNotFound {
      let payload = ToolResultPayload.failure(.init(message: "bookmark \"\(notFound.name)\" not found; name an existing bookmark or omit it to fold everything"))
      try await writeToolResult(.toolCall(callID), payload)
      return payload
    }

    let environment = transcript.environment
    let head = GenerationHead(
      id: uuid(),
      timestamp: date(),
      summary: arguments.summary,
      snapshot: .init(carrying: environment.tools, arguments: arguments),
      settle: environment.settle,
      runningWork: try await loopConfig.runningWork(id),
    )
    let closing = ToolResultItem(
      id: uuid(),
      timestamp: date(),
      provenance: .toolCall(callID),
      payload: .compact(.init(summary: arguments.summary)),
    )
    let transition: ModelRouteTransition?
    if let target = arguments.target {
      do {
        transition = try await loopConfig.prepareCompaction(id, transcript.compacted(head: head, kept: kept), target)
      } catch is CancellationError {
        throw CancellationError()
      } catch {
        let payload = ToolResultPayload.failure(.init(message: "compact target \"\(target.model)\" refused, nothing was folded: \(error)"))
        try await writeToolResult(.toolCall(callID), payload)
        return payload
      }
    } else {
      transition = try await loopConfig.prepareCompaction(id, transcript.compacted(head: head, kept: kept), nil)
    }
    span.set(.itemsKept, kept?.count ?? 0)
    let compacted = try await main.append(id, .compacted(closing: closing, head: head, kept: kept, completing: nil, transition: transition)).value(Transcript.self)
    try modify {
      $0.transcript = compacted
      $0.generation += 1
      $0.compactRequestClaim = nil
    }
    await loopConfig.invalidateInference(id)
    return closing.payload
  }

  func runInference(mode: InferenceMode) async throws {
    try await traced(.inference) { span in
      span.set(.inferenceMode, mode == .normal ? .normal : .forcedCompact)
      span.conclude(try await infer(mode: mode, span: span))
    }
  }

  private func infer(mode: InferenceMode, span: TelemetrySpan<InferenceOutcome>) async throws -> InferenceOutcome {
    if (try live).transcript.needsReestablishment {
      guard try await reestablish() else { return .cancelled }
    }

    let budget = await loopConfig.budget(id)
    let fullness = try live.transcript.contextFullness(budget: budget)
    try Task.checkCancellation()
    span.set(.contextFullness, fullness)
    let state = try live
    guard !state.revoking else { return .cancelled }
    if fullness >= loopConfig.thresholds.soft, !state.transcript.hasPendingPressureNotice {
      let percent = Int((fullness * 100).rounded())
      try await appended([.notification(.init(
        id: uuid(),
        timestamp: date(),
        kind: .context,
        subscriptionID: SubscriptionID("context-pressure"),
        content: .init(text: """
        <compaction-notice>
        Context is \(percent)% full. Compact at a natural boundary of your choosing: \
        call bookmark to mark a cut point, then compact to fold everything before it.
        </compaction-notice>
        """),
      ))])
    }

    var attempt = 0
    var idleTimeouts = 0
    var boundedFailures = 0
    var attempts = 0
    var backoffMs = 0
    defer {
      span.set(.attempts, attempts)
      span.set(.backoffMs, backoffMs)
    }
    while true {
      if case .interrupting = (try live).sessionStatus { return .cancelled }
      guard try await reconcileSubscriptions() else { return .cancelled }
      attempts += 1

      let attemptID = uuid()
      let request = InferenceRequest(
        sessionID: id,
        attemptID: attemptID,
        transcript: (try live).transcript,
        mode: mode,
        idleTimeout: idleTimeoutSchedule[idleTimeouts],
      )
      let compactClaim = mode == .forcedCompact ? (try live).compactRequestClaim : nil
      let cache = try live.cacheExpectation(now: date())
      let result = await runLongRunningTask { [loopConfig] in
        try await expectingCache(cache) { try await loopConfig.inference(request) }
      }

      switch result {
      case .success(let reply):
        var appended = (try live).transcript
        let before = appended.items.count
        let entry = appended.appendAssistant(reply.message, id: attemptID, metadata: reply.metadata, replayBinding: reply.replayBinding)
        // The model tried to finish. A nag due now is written with its message,
        // so the session never reads settled while it owes one.
        let now = date()
        if mode == .normal, entry.toolCalls.isEmpty, let nag = appended.environment.nag(task: (try live).isTask, now: now) {
          appended.append(.notification(nag.notification(id: uuid(), at: now)))
        }
        try await main.append(id, .transcriptAppended(items: Array(appended.items[before...]), inputOrigin: appended.cacheWarmingInputOrigin, completing: compactClaim)).value(Void.self)
        try modify {
          $0.transcript = appended
          if compactClaim != nil { $0.compactRequestClaim = nil }
          $0.malformedMessages = 0
          $0.capacityFailures = 0
          $0.compactedForPayload = false
          if let usage = reply.metadata.usage { $0.lastPrompt = .init(tokens: usage.inputTokens, at: now, generation: $0.generation) }
        }
        if mode == .normal { try modify { $0.inStep = false } }
        await reply.committed(entry, appended)
        try Task.checkCancellation()
        if mode == .forcedCompact, !reply.message.callsCompact {
          try await fallbackCompact(.forced)
        }
        return .ok

      case .failure(let boundary as ReplayBoundaryRequired):
        let state = try live
        let compacted: Transcript
        do {
          let portable = try state.transcript.portableHandoff(binding: boundary.binding, budget: boundary.budget, runningWork: try await loopConfig.runningWork(id))
          compacted = try await main.append(id, .portableHandoff(expectedGeneration: state.generation, source: state.transcript, transcript: portable)).value(Transcript.self)
        } catch {
          try Task.checkCancellation()
          await markErrored(error: error)
          return .errored
        }
        try modify {
          $0.transcript = compacted
          $0.generation += 1
          $0.compactRequestClaim = nil
        }
        await loopConfig.invalidateInference(id)
        return .handoff

      // A compaction during a quota wait folds mechanically, so placement can
      // move the next generation to a member with room.
      case .failure(let error) where mode == .forcedCompact && waitsOnQuota(error):
        return try await fallbackCompact(.forced) ? .compacted : .cancelled

      case .failure(let waiting as ModelRouteWaiting):
        guard try await backoff(attempt: 1, until: waiting.retryAt, adding: &backoffMs, mode: mode) else { return .cancelled }

      case .failure(let error):
        switch classify(error) {
        case .cancelled:
          return .cancelled
        case .capacity:
          try modify { $0.capacityFailures += 1 }
          if (try live).capacityFailures >= 3 {
            await markErrored(error: InferenceError.normalize(error))
            return .errored
          }
          attempt += 1
          guard try await backoff(attempt: attempt, adding: &backoffMs, mode: mode) else { return .cancelled }
        case .malformedModelMessage:
          try modify { $0.malformedMessages += 1 }
          if (try live).malformedMessages >= 3 {
            await markErrored(error: InferenceError.normalize(error))
            return .errored
          }
          idleTimeouts = 0
          boundedFailures = 0
          attempt += 1
          guard try await backoff(attempt: attempt, adding: &backoffMs, mode: mode) else { return .cancelled }
        case .outage(let retryAt):
          idleTimeouts = 0
          boundedFailures = 0
          attempt += 1
          guard try await backoff(attempt: attempt, until: retryAt, adding: &backoffMs, mode: mode) else { return .cancelled }
        case .transient(let timedOut):
          if timedOut {
            idleTimeouts += 1
            if idleTimeouts == idleTimeoutSchedule.count {
              Logger(label: "wuhu.loop").notice("inference parked after consecutive idle timeouts", metadata: [
                "session": "\(id.rawValue)",
                "consecutive_timeouts": "\(idleTimeouts)",
              ])
              return try await park(error, mode: mode)
            }
          } else {
            idleTimeouts = 0
          }
          boundedFailures += 1
          if boundedFailures == boundedFailureLimit {
            Logger(label: "wuhu.loop").notice("inference parked after consecutive unretryable failures", metadata: [
              "session": "\(id.rawValue)",
              "failures": "\(boundedFailures)",
              "error": "\(error)",
            ])
            return try await park(error, mode: mode)
          }
          attempt += 1
          guard try await backoff(attempt: attempt, adding: &backoffMs, mode: mode) else { return .cancelled }
        case .requestTooLarge(let normalized):
          let compactedError: InferenceError
          if case let .requestTooLarge(limit) = normalized {
            compactedError = .requestTooLargeAfterCompaction(limitBytes: limit)
          } else {
            compactedError = normalized
          }
          if (try live).compactedForPayload {
            await markErrored(error: compactedError)
            return .errored
          }
          do {
            guard try await fallbackCompact(.tooLarge) else { return .cancelled }
            try modify { $0.compactedForPayload = true }
            return .compacted
          } catch {
            guard case .requestTooLarge = classify(error) else { throw error }
            await markErrored(error: compactedError)
            return .errored
          }
        case .contextTooLong:
          return try await fallbackCompact(.contextTooLong) ? .compacted : .cancelled
        case .terminal:
          return try await park(error, mode: mode)
        }
      }
    }
  }

  private func park(_ error: any Error, mode: InferenceMode) async throws -> InferenceOutcome {
    if mode == .forcedCompact {
      return try await fallbackCompact(.forced) ? .compacted : .cancelled
    }
    await markErrored(error: error)
    return .parked
  }

  // Reads are idempotent, so the list reruns wholesale
  // on any doubt; false = cancelled mid-way, redone on the next pass.
  private func reestablish() async throws -> Bool {
    guard case let .generationHead(head) = (try live).transcript.items.first else {
      preconditionFailure("re-establishment requested without a generation head")
    }
    for call in head.reestablishmentCalls {
      let invocation = ToolInvocation(
        sessionID: id,
        call: call,
        state: (try live).transcript.environment.tools,
      )
      let result = await runLongRunningTask { [loopConfig] in
        try await loopConfig.executeTool(invocation)
      }
      switch result {
      case .success(let outcome):
        try await writeToolResult(.compactionReestablishment, outcome.payload, context: outcome.context)
        await outcome.committed?()
      case .failure(is CancellationError):
        return false
      case .failure(let error):
        try await writeToolResult(.compactionReestablishment, .failure(.init(message: String(describing: error))))
      }
    }
    return true
  }

  @discardableResult
  func fallbackCompact(_ reason: CompactionReason) async throws -> Bool {
    try await traced(.compaction) { span in
      span.set(.compactionReason, reason)
      span.set(.generation, liveState?.generation)
      let compacted = try await fallbackCompact(span: span)
      span.conclude(compacted ? .ok : .cancelled)
      return compacted
    }
  }

  private func fallbackCompact(span: TelemetrySpan<StepOutcome>) async throws -> Bool {
    guard try await reconcileSubscriptions() else { return false }
    let transcript = (try live).transcript
    let sessionID = id
    let compactClaim = try live.compactRequestClaim
    let result = await runLongRunningTask { [loopConfig] in
      try await loopConfig.compact(sessionID, transcript)
    }
    switch result {
    case .success(let outcome):
      let environment = transcript.environment
      let head = GenerationHead(
        id: uuid(),
        timestamp: date(),
        summary: outcome.summary,
        snapshot: .init(subscriptions: environment.tools.subscriptions, preReads: outcome.preReads),
        settle: environment.settle,
        runningWork: try await loopConfig.runningWork(id),
      )
      let transition = try await loopConfig.prepareCompaction(id, transcript.compacted(head: head, kept: outcome.kept), nil)
      span.set(.itemsKept, outcome.kept?.count ?? 0)
      let compacted = try await main.append(id, .compacted(closing: nil, head: head, kept: outcome.kept, completing: compactClaim, transition: transition)).value(Transcript.self)
      try modify {
        $0.transcript = compacted
        $0.generation += 1
        $0.compactRequestClaim = nil
      }
      await loopConfig.invalidateInference(id)
      return true
    case .failure(is CancellationError):
      return false
    case .failure(let error):
      // Fallback compaction failing is terminal: the looper parks the session.
      throw error
    }
  }

  /// False when the wait was cut: cancelled, or in normal mode a pending compact command, which
  /// `nextStep` takes once the inference returns.
  private func backoff(attempt: Int, until retryAt: Date? = nil, adding waited: inout Int, mode: InferenceMode) async throws -> Bool {
    if mode == .normal { compactYield = .open }
    defer { compactYield = .closed }
    if mode == .normal {
      let pending = try await main.pendingCommand(id) != nil
      if pending || compactYield == .requested { return false }
    }
    let delay: Double
    if let wait = retryAt.map({ $0.timeIntervalSince(date()) }), wait > 0 {
      delay = min(retryAtCeiling, wait)
    } else {
      let raw = min(backoffCeiling, pow(2.0, Double(attempt - 1)))
      let jitter = withRandomNumberGenerator { generator in
        Double.random(in: 0 ... 1, using: &generator)
      }
      delay = raw * jitter
    }
    waited += Int((delay * 1000).rounded())
    let sleep = deadlineSleep(after: .seconds(delay), clock: clock)
    let pause = try? taskScope.run("session-retry") { try await sleep() }
    retryPause = pause
    defer { retryPause = nil }
    return await withTaskCancellationHandler {
      if case .failure = await pause?.result { return false }
      return !Task.isCancelled
    } onCancel: { pause?.cancel() }
  }

  @discardableResult
  func writeToolResult(
    _ provenance: ToolResultItem.Provenance,
    _ payload: ToolResultPayload,
    context: ScopeContext? = nil,
  ) async throws -> ToolResultPayload {
    // The backstop, not the budget: whatever the tool layer missed must not
    // enter the transcript unclamped.
    let item = ToolResultItem(id: uuid(), timestamp: date(), provenance: provenance, payload: payload.clamped())
    var items: [TranscriptItem] = [.toolResult(item)]
    if let context {
      items.append(.notification(context.notice(id: uuid(), at: date())))
    }
    try await appended(items)
    return item.payload
  }

  // The in-memory transcript is the truth the loop renders from; the store is
  // told what to persist and what the result is, never asked to read it back.
  func appended(_ items: [TranscriptItem]) async throws {
    var appended = (try live).transcript
    for item in items { appended.append(item) }
    try await main.append(id, .transcriptAppended(items: items, inputOrigin: appended.cacheWarmingInputOrigin, completing: nil)).value(Void.self)
    try modify { $0.transcript = appended }
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

private enum FailureClass {
  case cancelled
  case malformedModelMessage
  case capacity
  case outage(retryAt: Date?)
  case transient(timedOut: Bool)
  case contextTooLong
  case requestTooLarge(InferenceError)
  case terminal
}

// Normalized, never downcast: the inference seam admits any error, and the
// hops before the model stream (catalog resolution, credential refresh) carry
// their own vocabularies. A downcast reads every one of them as terminal.
private func classify(_ error: any Error) -> FailureClass {
  let normalized = InferenceError.normalize(error)
  return switch normalized {
  case .cancelled: .cancelled
  // Throttling and an unreachable network are the two failures that state
  // outright they are about right now rather than about the request.
  case .malformedModelMessage: .malformedModelMessage
  case .rateLimited(let retryAt): .outage(retryAt: retryAt)
  // Only a silent model stream escalates the idle-timeout schedule: it is the
  // one transport failure that re-burned the prompt to learn nothing.
  case .transport(.idleTimeout): .transient(timedOut: true)
  case .transport: .outage(retryAt: nil)
  case .streamCut, .transient, .upstreamUnavailable: .transient(timedOut: false)
  case .contextTooLong: .contextTooLong
  case .requestTooLarge: .requestTooLarge(normalized)
  case let .capacityExceeded(code, _, _):
    code == "response_too_large" || code == "websocket_message_too_large"
      ? .requestTooLarge(normalized) : .capacity
  case .requestTooLargeAfterCompaction, .oidcSigningFailed, .credentialRefreshRefused, .authenticationRefused, .invalidInput, .other: .terminal
  }
}

private func waitsOnQuota(_ error: any Error) -> Bool {
  if error is ModelRouteWaiting { return true }
  if case .rateLimited = InferenceError.normalize(error) { return true }
  return false
}

extension AssistantMessage {
  fileprivate var callsCompact: Bool {
    content.contains { block in
      guard case let .toolCall(call) = block else { return false }
      return call.name == KernelTool.compact.rawValue
    }
  }
}

extension Transcript {
  fileprivate var hasPendingPressureNotice: Bool {
    for item in items.reversed() {
      switch item {
      case .assistant, .generationHead:
        return false
      case let .notification(notification) where notification.kind == .context && notification.subscriptionID == SubscriptionID("context-pressure") && !notification.content.text.isEmpty:
        return true
      default:
        continue
      }
    }
    return false
  }
}
