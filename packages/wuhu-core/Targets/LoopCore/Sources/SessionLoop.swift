import Dependencies
import enum Fetch.TransportFailureKind
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
  func loop() async throws {
    // A cancelled pass (retirement, shutdown) must stop before its next
    // state read: only live sessions may read state. The check must precede
    // every `live` access — a buffered nudge can re-enter after dismount.
    try Task.checkCancellation()

    // nil = pass in flight (idleSince suppressed); restored on every exit so
    // a settled session is evictable.
    let mountID = try live.mountID
    try modify { $0.lastUpdatedByLoopAt = nil }
    defer {
      if liveState?.mountID == mountID { liveState?.lastUpdatedByLoopAt = date() }
    }

    while true {
      try Task.checkCancellation()

      guard !(try live).archiving else { return }
      switch (try live).sessionStatus {
      case .interrupted, .errored:
        return
      case .interrupting(let callback):
        callback.resume(with: .success(()))
        // A buffered nudge can re-enter before handleInterrupt persists;
        // flipping here keeps the callback single-shot.
        try modify { $0.sessionStatus = .interrupted }
        return
      case .healthy:
        break
      }

      guard try await refreshRegisteredSubscriptions() else { return }
      if let toolCall = (try live).transcript.nextPendingToolCall {
        try await execute(toolCall)
        continue
      }
      let budget = await loopConfig.budget(id)
      let fullness = try live.transcript.contextFullness(budget: budget)
      try Task.checkCancellation()
      guard !(try live).archiving else { return }
      if fullness >= loopConfig.thresholds.hard {
        try await runInference(mode: .forcedCompact)
      } else if (try live).queueHead > (try live).queueTail {
        try await drainQueue()
      } else {
        guard !(try live).archiving else { return }
        await beforeCompactRequest()
        let forced = try await takeCompactRequest()
        try Task.checkCancellation()
        guard !(try live).archiving else { return }
        if forced {
          try await runInference(mode: .forcedCompact)
        } else if (try live).transcript.hasWork {
          try await runInference(mode: .normal)
        } else if let nag = try idleNag() {
          try await appended([.notification(nag.notification(id: uuid(), at: date()))])
        } else {
          return
        }
      }
    }
  }

  // The operator-facing compact verb, the kernel's counterpart to Claude
  // Code's `/compact` command: instructions land as one system
  // notification, and the turn that follows is tool-choice-pinned to compact.
  func takeCompactRequest() async throws -> Bool {
    guard !(try live).archiving else { return false }
    guard try await repo.pendingCommand() != nil else { return false }
    try Task.checkCancellation()
    guard !(try live).archiving else { return false }
    let mountID = try live.mountID
    try modify { $0.claimingCompactRequest = true }
    defer {
      if liveState?.mountID == mountID { liveState?.claimingCompactRequest = false }
    }
    guard let claim = try await repo.claimCompactRequest(generation: (try live).generation) else { return false }
    try modify {
      $0.transcript = claim.transcript
      $0.compactRequestClaim = claim
    }
    return true
  }

  // Only a model that stopped is asked whether it may; a generation that never
  // ran (created, restarted) is inert. What is left is a park wake.
  private func idleNag() throws -> Nag? {
    guard case .assistant? = (try live).transcript.items.last else { return nil }
    return try nagOrScheduleWake((try live).transcript.environment)
  }

  private func refreshRegisteredSubscriptions() async throws -> Bool {
    let registered = try await repo.sessions.registeredSubscriptions(id)
    try Task.checkCancellation()
    guard !(try live).archiving else { return false }
    try modify {
      $0.transcript.registeredSubscriptions = registered.ids
      $0.transcript.handlerSubscriptions = registered.handlers
    }
    return true
  }

  func drainQueue() async throws {
    let drain = try await repo.drainQueue()
    try modify {
      for item in drain.items { $0.transcript.append(item) }
      $0.queueTail = drain.queueTail
      $0.queueHead = max($0.queueHead, drain.queueTail)
    }
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
    let work = Task<Result<T, any Error>, Never> {
      do {
        return .success(try await body())
      } catch {
        return .failure(error)
      }
    }
    let handle = Task<Void, Never> {
      await withTaskCancellationHandler {
        _ = await work.value
      } onCancel: {
        work.cancel()
      }
    }
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
      try await repo.markErrored(errorDescription: errorDescription)
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
  func execute(_ toolCall: ToolCall) async throws {
    switch KernelTool(rawValue: toolCall.name) {
    case .bookmark:
      return try await executeBookmark(toolCall)
    case .compact:
      return try await executeCompact(toolCall)
    case nil:
      break
    }

    let invocation = ToolInvocation(
      sessionID: id,
      call: toolCall,
      state: (try live).transcript.environment.tools,
    )
    let result = await runLongRunningTask { [loopConfig] in
      try await loopConfig.executeTool(invocation)
    }

    let callID = ToolCallID(toolCall.id)
    switch result {
    case .success(let payload):
      // Even when cancelled, a real result means the side effects happened:
      // commit it.
      try await writeToolResult(.toolCall(callID), payload, deliveredBy: callID)
    case .failure(is CancellationError):
      // Interrupt marks the tool so resume never retries it; a crash-shaped
      // cancellation (retirement, teardown) marks nothing and restart retries.
      guard !Task.isCancelled else { return }
      if case .interrupting = (try live).sessionStatus {
        await loopConfig.killInterruptedTool(invocation)
        try await writeToolResult(.toolCall(callID), .failure(.init(message: interruptedToolMessage)))
      }
    case .failure(let error):
      try await writeToolResult(.toolCall(callID), .failure(.init(message: String(describing: error))))
    }
  }

  private func executeBookmark(_ toolCall: ToolCall) async throws {
    let arguments: BookmarkArguments
    do {
      arguments = try decodeArguments(BookmarkArguments.self, from: toolCall)
    } catch {
      try await writeToolResult(
        .toolCall(.init(toolCall.id)),
        .failure(.init(message: "invalid bookmark arguments: \(error)")),
      )
      return
    }
    let marker = BookmarkMarker(
      id: uuid(),
      timestamp: date(),
      name: arguments.name,
      toolCallID: .init(toolCall.id),
    )
    try await appended([.bookmark(marker)])
  }

  private func executeCompact(_ toolCall: ToolCall) async throws {
    let callID = ToolCallID(toolCall.id)
    let arguments: CompactArguments
    do {
      arguments = try decodeArguments(CompactArguments.self, from: toolCall)
    } catch {
      try await writeToolResult(
        .toolCall(callID),
        .failure(.init(message: "invalid compact arguments: \(error)")),
      )
      return
    }

    let transcript = (try live).transcript
    let kept: Range<Int>?
    do {
      kept = try transcript.compactKeptRange(callID: callID, bookmark: arguments.bookmark)
    } catch let notFound as BookmarkNotFound {
      try await writeToolResult(
        .toolCall(callID),
        .failure(.init(message: "bookmark \"\(notFound.name)\" not found; name an existing bookmark or omit it to fold everything")),
      )
      return
    }

    let environment = transcript.environment
    let head = GenerationHead(
      id: uuid(),
      timestamp: date(),
      summary: arguments.summary,
      snapshot: .init(carrying: environment.tools, arguments: arguments),
      settle: environment.settle,
    )
    let closing = ToolResultItem(
      id: uuid(),
      timestamp: date(),
      provenance: .toolCall(callID),
      payload: .compact(.init(summary: arguments.summary)),
    )
    let compacted = try await repo.writeCompaction(closing: closing, head: head, kept: kept)
    try modify {
      $0.transcript = compacted
      $0.generation += 1
      $0.compactRequestClaim = nil
    }
    await loopConfig.invalidateInference(id)
  }

  func runInference(mode: InferenceMode) async throws {
    if (try live).transcript.needsReestablishment {
      guard try await reestablish() else { return }
    }

    let budget = await loopConfig.budget(id)
    let fullness = try live.transcript.contextFullness(budget: budget)
    try Task.checkCancellation()
    let state = try live
    guard !state.archiving else { return }
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
    while true {
      if case .interrupting = (try live).sessionStatus { return }
      guard try await refreshRegisteredSubscriptions() else { return }

      let attemptID = uuid()
      let request = InferenceRequest(
        sessionID: id,
        attemptID: attemptID,
        transcript: (try live).transcript,
        mode: mode,
        idleTimeout: idleTimeoutSchedule[idleTimeouts],
      )
      let compactClaim = mode == .forcedCompact ? (try live).compactRequestClaim : nil
      let result = await runLongRunningTask { [loopConfig] in
        try await loopConfig.inference(request)
      }

      switch result {
      case .success(let reply):
        var appended = (try live).transcript
        let before = appended.items.count
        let entry = appended.appendAssistant(reply.message, id: attemptID, metadata: reply.metadata)
        // The model tried to finish. A nag due now is written with its message,
        // so the session never reads settled while it owes one.
        let now = date()
        if mode == .normal, entry.toolCalls.isEmpty, let nag = appended.environment.nag(task: (try live).isTask, now: now) {
          appended.append(.notification(nag.notification(id: uuid(), at: now)))
        }
        try await repo.append(Array(appended.items[before...]), transcript: appended, completingCompactRequest: compactClaim)
        try modify {
          $0.transcript = appended
          if compactClaim != nil { $0.compactRequestClaim = nil }
          $0.malformedMessages = 0
          $0.capacityFailures = 0
          $0.compactedForPayload = false
        }
        await reply.committed(entry, appended)
        try Task.checkCancellation()
        if mode == .forcedCompact, !reply.message.callsCompact {
          try await fallbackCompact()
        }
        return

      case .failure(let error):
        switch classify(error) {
        case .cancelled:
          return
        case .capacity:
          try modify { $0.capacityFailures += 1 }
          if (try live).capacityFailures >= 3 {
            await markErrored(error: InferenceError.normalize(error))
            return
          }
          attempt += 1
          guard await backoff(attempt: attempt) else { return }
        case .malformedModelMessage:
          try modify { $0.malformedMessages += 1 }
          if (try live).malformedMessages >= 3 {
            await markErrored(error: InferenceError.normalize(error))
            return
          }
          idleTimeouts = 0
          boundedFailures = 0
          attempt += 1
          guard await backoff(attempt: attempt) else { return }
        case .outage(let retryAt):
          idleTimeouts = 0
          boundedFailures = 0
          attempt += 1
          guard await backoff(attempt: attempt, until: retryAt) else { return }
        case .transient(let timedOut):
          if timedOut {
            idleTimeouts += 1
            if idleTimeouts == idleTimeoutSchedule.count {
              Logger(label: "wuhu.loop").notice("inference parked after consecutive idle timeouts", metadata: [
                "session": "\(id.rawValue)",
                "consecutive_timeouts": "\(idleTimeouts)",
              ])
              try await park(error, mode: mode)
              return
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
            try await park(error, mode: mode)
            return
          }
          attempt += 1
          guard await backoff(attempt: attempt) else { return }
        case .requestTooLarge(let normalized):
          let compactedError: InferenceError
          if case let .requestTooLarge(limit) = normalized {
            compactedError = .requestTooLargeAfterCompaction(limitBytes: limit)
          } else {
            compactedError = normalized
          }
          if (try live).compactedForPayload {
            await markErrored(error: compactedError)
            return
          }
          do {
            if try await fallbackCompact() {
              try modify { $0.compactedForPayload = true }
            }
          } catch {
            if case .requestTooLarge = classify(error) {
              await markErrored(error: compactedError)
            } else {
              throw error
            }
          }
          return
        case .contextTooLong:
          try await fallbackCompact()
          return
        case .terminal:
          try await park(error, mode: mode)
          return
        }
      }
    }
  }

  private func park(_ error: any Error, mode: InferenceMode) async throws {
    if mode == .forcedCompact {
      try await fallbackCompact()
    } else {
      await markErrored(error: error)
    }
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
      case .success(let payload):
        try await writeToolResult(.compactionReestablishment, payload, deliveredBy: ToolCallID(call.id))
      case .failure(is CancellationError):
        return false
      case .failure(let error):
        try await writeToolResult(.compactionReestablishment, .failure(.init(message: String(describing: error))))
      }
    }
    return true
  }

  @discardableResult
  func fallbackCompact() async throws -> Bool {
    guard try await refreshRegisteredSubscriptions() else { return false }
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
      )
      let compacted = try await repo.writeCompaction(closing: nil, head: head, kept: outcome.kept, completingCompactRequest: compactClaim)
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

  private func backoff(attempt: Int, until retryAt: Date? = nil) async -> Bool {
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
    let result = await runLongRunningTask { [clock] in
      try await clock.sleep(for: .seconds(delay))
    }
    if case .failure = result { return false }
    return true
  }

  func writeToolResult(
    _ provenance: ToolResultItem.Provenance,
    _ payload: ToolResultPayload,
    deliveredBy callID: ToolCallID? = nil,
  ) async throws {
    // The backstop, not the budget: whatever the tool layer missed must not
    // enter the transcript unclamped.
    let item = ToolResultItem(id: uuid(), timestamp: date(), provenance: provenance, payload: payload.clamped())
    var items: [TranscriptItem] = [.toolResult(item)]
    if let callID, let context = try await repo.scopeContext(callID) {
      items.append(.notification(context.notice(id: uuid(), at: date())))
    }
    try await appended(items)
  }

  // The in-memory transcript is the truth the loop renders from; the store is
  // told what to persist and what the result is, never asked to read it back.
  private func appended(_ items: [TranscriptItem]) async throws {
    var appended = (try live).transcript
    for item in items { appended.append(item) }
    try await repo.append(items, transcript: appended)
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
  case .transient: .transient(timedOut: false)
  case .contextTooLong: .contextTooLong
  case .requestTooLarge: .requestTooLarge(normalized)
  case let .capacityExceeded(code, _, _):
    code == "response_too_large" || code == "websocket_message_too_large"
      ? .requestTooLarge(normalized) : .capacity
  case .requestTooLargeAfterCompaction, .invalidInput, .other: .terminal
  }
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
      case let .notification(notification) where notification.kind == .context && notification.subscriptionID == SubscriptionID("context-pressure"):
        return true
      default:
        continue
      }
    }
    return false
  }
}
