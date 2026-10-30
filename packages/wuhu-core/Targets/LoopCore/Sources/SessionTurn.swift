import ServerTelemetry
import SessionDomain
import struct SpaceContract.GroupID
import SpaceCore
import struct WuhuAI.ToolCall
#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif

extension SessionActor {
  enum Step {
    case tool(ToolCall), drain, compaction(requested: Bool), inference, nag(Nag)
  }

  /// One pass: a turn span opens only once there is a first step, so a pass that finds nothing records nothing.
  func loop() async throws {
    try Task.checkCancellation()
    guard var step = try await nextStep() else { return }
    let state = try live
    try modify { $0.turnsSinceMount += 1 }
    try await traced(.turn, under: .root(SpanOwner(session: id, group: GroupID(rawValue: state.group)))) { span in
      var turn = TurnTrace(span: span, startedAt: date())
      span.set(.sessionKind, state.isTask ? .task : .agent)
      span.set(.parentSession, state.parent)
      span.set(.generation, state.generation)
      span.set(.trigger, step.trigger(restart: state.turnsSinceMount == 0))
      defer {
        span.set(.steps, turn.inferences)
        span.set(.toolCalls, turn.toolCalls)
      }
      while true {
        try await run(step, turn: &turn)
        try modify { $0.inStep = false }
        turn.pastFirstStep = true
        guard let next = try await nextStep() else { break }
        step = next
      }
      span.conclude(.ok)
    }
  }

  private func run(_ step: Step, turn: inout TurnTrace) async throws {
    try modify { $0.inStep = true }
    switch step {
    case let .tool(call):
      turn.toolCalls += 1
      try await execute(call)
    case .drain:
      try await drainQueue(into: &turn)
    case .compaction:
      turn.inferences += 1
      try await runForcedCompaction()
    case .inference:
      turn.inferences += 1
      try await runInference(mode: .normal)
    case let .nag(nag):
      try await appended([.notification(nag.notification(id: uuid(), at: date()))])
    }
  }

  private func nextStep() async throws -> Step? {
    // A cancelled pass (retirement, shutdown) must stop before its next
    // state read: only live sessions may read state. The check must precede
    // every `live` access — a buffered nudge can re-enter after dismount.
    try Task.checkCancellation()
    guard !(try live).revoking else { return nil }
    switch (try live).sessionStatus {
    case .interrupted, .errored:
      return nil
    case .interrupting(let callback):
      callback.resume(with: .success(()))
      // A buffered nudge can re-enter before handleInterrupt persists;
      // flipping here keeps the callback single-shot.
      try modify { $0.sessionStatus = .interrupted }
      return nil
    case .healthy:
      break
    }

    if (try live).transcript.hasPendingCacheWarming, try await !loopConfig.allowCacheWarming(id) {
      let transcript = try await main.append(id, .pendingCacheWarmingDiscarded).value(Transcript.self)
      try modify { $0.transcript = transcript }
    }
    guard try await reconcileSubscriptions() else { return nil }
    if let toolCall = (try live).transcript.nextPendingToolCall { return .tool(toolCall) }
    let budget = await loopConfig.budget(id)
    let fullness = try live.transcript.contextFullness(budget: budget)
    try Task.checkCancellation()
    guard !(try live).revoking else { return nil }
    if fullness >= loopConfig.thresholds.hard { return .compaction(requested: false) }
    if (try live).queueHead > (try live).queueTail { return .drain }
    await beforeCompactRequest()
    let forced = try await takeCompactRequest()
    try Task.checkCancellation()
    guard !(try live).revoking else { return nil }
    if forced { return .compaction(requested: true) }
    if (try live).transcript.hasWork { return .inference }
    let nag = try await idleNag()
    guard !(try live).revoking else { return nil }
    return nag.map(Step.nag)
  }

  func drainQueue(into turn: inout TurnTrace) async throws {
    let drain = try await main.drainQueue(id)
    try modify {
      for item in drain.items { $0.transcript.append(item) }
      $0.queueTail = drain.queueTail
      $0.queueHead = max($0.queueHead, drain.queueTail)
    }
    turn.record(drain, at: date())
  }
}

extension SessionActor.Step {
  /// Nil for a drain: its first input names the trigger.
  fileprivate func trigger(restart: Bool) -> TurnTrigger? {
    switch self {
    case .drain: nil
    case .nag: .nag
    case .compaction(requested: true): .compact
    case .tool, .inference, .compaction(requested: false): restart ? .restart : .resume
    }
  }
}

struct TurnTrace {
  let span: TelemetrySpan<StepOutcome>
  let startedAt: Date
  var inferences = 0
  var toolCalls = 0
  var pastFirstStep = false

  init(span: TelemetrySpan<StepOutcome>, startedAt: Date) {
    self.span = span
    self.startedAt = startedAt
  }

  /// A drain that is the turn's first step names its trigger and inputs; any later one is an event.
  mutating func record(_ drain: QueueDrain, at now: Date) {
    guard span.isRecording, let first = drain.items.first else { return }
    var inputs = DrainedInputs()
    for item in drain.items { inputs.add(item) }
    let wait = inputs.oldest.map { max(0, Int(((pastFirstStep ? now : startedAt).timeIntervalSince($0) * 1000).rounded())) }
    let fill = { (fields: inout SpanFields) in
      fields.set(.queueWaitMs, wait)
      fields.set(.inputMessages, inputs.messages.nonEmpty)
      fields.set(.inputRequests, inputs.requests.nonEmpty)
      fields.set(.inputSenders, inputs.senders.nonEmpty)
      fields.set(.inputSubscriptions, inputs.subscriptions.nonEmpty)
      fields.set(.inputFirings, drain.firings.nonEmpty)
    }
    if pastFirstStep {
      span.event(.drained, fill)
    } else {
      span.set(.trigger, first.trigger)
      span.set(fill)
    }
  }
}

private struct DrainedInputs {
  var messages: [MessageID] = []
  var requests: [RequestID] = []
  var senders: [SessionID] = []
  var subscriptions: [SubscriptionID] = []
  /// When the oldest input was sent, which is when it was queued.
  var oldest: Date?

  mutating func add(_ item: TranscriptItem) {
    switch item {
    case let .message(message):
      oldest = min(oldest ?? message.timestamp, message.timestamp)
      messages.append(message.messageID)
      if let request = message.requestID { requests.append(request) }
      if let sender = message.senderSession, !senders.contains(sender) { senders.append(sender) }
    case let .notification(notification):
      oldest = min(oldest ?? notification.timestamp, notification.timestamp)
      if let request = notification.requestID { requests.append(request) }
      subscriptions.append(notification.subscriptionID)
    default:
      break
    }
  }
}

extension TranscriptItem {
  fileprivate var trigger: TurnTrigger {
    switch self {
    case let .message(message):
      switch message.kind {
      case .message: .message
      case .request: .request
      case .progress, .final: .report
      }
    case let .notification(notification):
      switch notification.kind {
      case .timer: .timer
      case .spaceObservation: .observation
      case .script, .exec: .script
      case .compactRequest: .compact
      case .owedReply, .parkReminder: .nag
      case .context: notification.isCacheWarming ? .cacheWarm : .notice
      case .childFailed, .requestDeadline, .requestStall: .notice
      }
    default:
      .notice
    }
  }
}

extension Array {
  fileprivate var nonEmpty: Self? { isEmpty ? nil : self }
}
