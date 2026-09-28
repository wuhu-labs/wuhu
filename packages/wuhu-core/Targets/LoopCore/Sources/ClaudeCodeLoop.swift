import ClaudeStream
import Foundation
import JSONValue
import Logging
import OrderedCollections
import SessionDomain
import SpaceCore

struct ClaudeCodeLive {
  struct Activation {
    let id: UUID
    let process: ClaudeCodeProcess
    var pump: Task<Void, Never>?
  }

  // What was handed over and not yet seen in the mirror. While a hook is
  // still rendering the slot is taken, and nothing else goes out.
  enum Handover {
    case rendering(at: Date)
    case outstanding(ClaudeCodeHandover)

    var at: Date {
      switch self {
      case let .rendering(at): at
      case let .outstanding(handover): handover.at
      }
    }

    var outstanding: ClaudeCodeHandover? {
      if case let .outstanding(handover) = self { handover } else { nil }
    }
  }

  enum Opening {
    case deliveries
    case reminders(Nag?)
  }

  enum Continuation: Hashable {
    case restarted
    case exited(String)
    case interrupted
    case errored(String)

    var reason: String {
      switch self {
      case .restarted: "Wuhu restarted while it ran"
      case let .exited(how): "the Claude Code process exited: \(how)"
      case .interrupted: "it was interrupted"
      case let .errored(message): "it ended with an error: \(message)"
      }
    }
  }

  var activation: Activation?
  var turnRunning = false
  var handover: Handover?
  var continuation: Continuation?
  var cutOffs = 0
  var stopping = false
  // A `/compact` is on standard input and its result has not come back:
  // steering, not work, and nothing else goes in until it ends.
  var compacting = false
  var contextTokens: Int?
  // The running turn's standard-input handover time: receipts recorded since
  // belong to it even before its entries are stored.
  var turnStartedAt: Date?
  // A turn claimed past the archive check and not yet running: its spawn and
  // store write are still to come, so archive must wait for it.
  var starting = false
  // Set when a turn ends, at load and when a park wake fires: the next idle
  // pass reads the session environment for a nag or a wake.
  var evaluate = true
  // Claude Code may flush a turn's log after its result: a handover still
  // unconfirmed then stays outstanding, and only this gives it up.
  var backstop: Task<Void, Never>?
  // The text of the turn's latest API error entry, for a result that
  // fails without saying why.
  var apiError: String?

  var isQuiet: Bool { !turnRunning && !starting && !compacting && handover == nil && continuation == nil }

  init(hydration: SessionHydration) {
    switch hydration.record.work {
    case .errored:
      continuation = .errored(hydration.record.errorMessage ?? "unknown error")
    case .hasWork where hydration.undrained.isEmpty:
      continuation = hydration.record.hold == .interrupted ? .interrupted : .restarted
    case .hasWork, .noWork:
      continuation = nil
    }
  }
}

// How long a handover may stay unconfirmed after its turn's result before it
// is taken as lost and goes again.
let claudeCodeHandoverBackstop = Duration.seconds(5)

// Consecutive cut-offs with no finished turn between them before the session
// errors; each continuation waits 2^(n-1) seconds first.
let claudeCodeCutOffLimit = 3

extension SessionActor {
  func claudeCodeLoop() async throws {
    var waited = false
    while true {
      try Task.checkCancellation()
      switch live.sessionStatus {
      case .interrupted, .errored:
        return
      case let .interrupting(callback):
        await stopClaudeCodeActivation(continuing: .interrupted)
        callback.resume(with: .success(()))
        live.sessionStatus = .interrupted
        return
      case .healthy:
        break
      }
      // A running turn is driven by its frames; the turn's end nudges.
      if live.claude.turnRunning || live.claude.stopping || live.claude.handover != nil || live.claude.compacting || live.archiving { return }
      guard live.queueHead > live.queueTail || live.claude.continuation != nil else {
        if try await compactOnRequest() { return }
        guard live.claude.evaluate else { return }
        // An automatic compaction happened in a turn whose hooks may all
        // have run before the notice was owed; like a nag, it goes in now.
        let notice = try await repo.claudeCodeOwedCompactionNotice()
        try Task.checkCancellation()
        let nag = try await claudeCodeNagOrWake()
        guard nag != nil || notice == .automatic else { return }
        try await startClaudeCodeTurn(.reminders(nag))
        continue
      }
      if let continuation = live.claude.continuation, live.claude.cutOffs > 0, !waited {
        guard live.claude.cutOffs < claudeCodeCutOffLimit else {
          await markErrored(error: ClaudeCodeCutOff(count: live.claude.cutOffs, last: continuation))
          return
        }
        let wait = Duration.seconds(1 << (live.claude.cutOffs - 1))
        let slept = await runLongRunningTask { [clock] in try await clock.sleep(for: wait) }
        guard case .success = slept else { return }
        waited = true
        continue
      }
      try await startClaudeCodeTurn()
    }
  }

  private func claudeCodeNagOrWake() async throws -> Nag? {
    let environment = try await repo.claudeCodeEnvironment(pendingSince: nil)
    try Task.checkCancellation()
    live.claude.evaluate = false
    return nagOrScheduleWake(environment)
  }

  // `wuhu session compact`: taken only with no turn running and nothing to
  // deliver. A session with no log yet has
  // nothing to compact, and the command is dropped.
  private func compactOnRequest() async throws -> Bool {
    let pending = try await repo.pendingCommand() != nil
    try Task.checkCancellation()
    guard pending, case let .compact(instructions)? = try await repo.takeCommand() else { return false }
    try Task.checkCancellation()
    let activation: ClaudeCodeLive.Activation
    if let running = live.claude.activation {
      activation = running
    } else {
      let log = try await repo.claudeCodeLog()
      try Task.checkCancellation()
      guard !log.entries.isEmpty else { return false }
      activation = try await ensureClaudeCodeActivation(log: log)
    }
    try modify { $0.claude.compacting = true }
    let command = instructions.flatMap { $0.isEmpty ? nil : "/compact \($0)" } ?? "/compact"
    do {
      try await activation.process.write(claudeCodeUserMessage(uuid: uuid().uuidString.lowercased(), content: [.text(command)]))
    } catch {
      Logger(label: "wuhu.loop").warning("Claude Code standard input failed", metadata: [
        "session": "\(id.rawValue)", "error": "\(error)",
      ])
      activation.process.kill()
    }
    return true
  }

  // Reminders (a nag, a compaction notice) go alone: rows and continuations
  // come first and the end-of-turn gate reminds their turn.
  private func startClaudeCodeTurn(_ opening: ClaudeCodeLive.Opening = .deliveries) async throws {
    let (reminders, nag): (Bool, Nag?) = switch opening {
    case .deliveries: (false, nil)
    case let .reminders(nag): (true, nag)
    }
    let entries = reminders ? [] : try await repo.undrainedInputs()
    let note = reminders ? nil : try await repo.claudeCodePendingNote()
    let notice = try await repo.claudeCodeOwedCompactionNotice() != nil
    let armed = notice ? try await repo.armedSubscriptions() : []
    try Task.checkCancellation()
    let continuation = reminders ? nil : live.claude.continuation
    guard !entries.isEmpty || continuation != nil || nag != nil || (reminders && notice) else {
      if !reminders { try modify { $0.queueHead = $0.queueTail } }
      return
    }
    var content: [ClaudeCodeBlock] = []
    if notice {
      content.append(.text(compactionNotice(armed)))
    }
    if let nag {
      content.append(.text(nag.rendered(at: date())))
    }
    if let note {
      content.append(.text(systemNotice(note, source: "session.restart")))
    }
    if let continuation {
      content.append(.text(systemNotice(SessionPrompt.continuation(reason: continuation.reason), source: "session.continuation")))
    }
    content += try await loopConfig.claudeCode.render(id, entries.map(\.input), .standardInput)
    try Task.checkCancellation()
    guard !live.archiving else {
      if reminders { live.claude.evaluate = true }
      return
    }
    live.claude.starting = true
    defer { if !Task.isCancelled { live.claude.starting = false } }
    let activation = try await ensureClaudeCodeActivation()
    let uuid = uuid().uuidString.lowercased()
    try await repo.beginClaudeCodeTurn()
    try modify {
      $0.claude.handover = .outstanding(.init(
        record: .userEntry(uuid: uuid), through: entries.last?.id, note: note != nil, nag: nag, compactionNotice: notice, at: date(),
      ))
      $0.claude.turnRunning = true
      $0.claude.turnStartedAt = date()
      $0.claude.apiError = nil
      if !reminders { $0.claude.continuation = nil }
    }
    do {
      try await activation.process.write(claudeCodeUserMessage(uuid: uuid, content: content))
    } catch {
      // The pump sees the exit and counts the cut-off.
      Logger(label: "wuhu.loop").warning("Claude Code standard input failed", metadata: [
        "session": "\(id.rawValue)", "error": "\(error)",
      ])
      activation.process.kill()
    }
  }

  private func systemNotice(_ text: String, source: String) -> String {
    MessageHeader.systemNotice(source: SubscriptionID(source), at: date()).render() + "\n\n" + text
  }

  // Only what the session may cancel itself: a request deadline ends with the
  // task's final report, and a park reminder is the loop's own.
  private func compactionNotice(_ armed: [ArmedSubscription]) -> String {
    let active = armed.compactMap { armed -> String? in
      let id = armed.slot.id.rawValue
      return switch armed.slot.kind {
      case let .timer(.cron(expression), message): "- \(id): timer, cron \(expression), message \(quoted(message))"
      case let .timer(.oneShot(at), message): "- \(id): timer, fires \(at.formatted(.iso8601)), message \(quoted(message))"
      case let .observe(sql, _): "- \(id): observation, \(quoted(sql))"
      case .requestDeadline, .parkReminder: nil
      }
    }
    let listing = active.isEmpty ? nil : (["Your active timers and observations; cancel_timer and cancel_observation take these ids:"] + active)
      .joined(separator: "\n")
    return systemNotice(
      [SessionPrompt.compactionNudge(session: id), listing].compactMap(\.self).joined(separator: "\n\n"),
      source: "session.compaction",
    )
  }

  private func ensureClaudeCodeActivation(log known: ClaudeCodeLog? = nil) async throws -> ClaudeCodeLive.Activation {
    if let activation = live.claude.activation { return activation }
    let log = if let known { known } else { try await repo.claudeCodeLog() }
    let activationID = uuid()
    let process = try await loopConfig.claudeCode.spawn(ClaudeCodeLaunch(session: id, activation: activationID, log: log))
    try Task.checkCancellation()
    var activation = ClaudeCodeLive.Activation(id: activationID, process: process)
    activation.pump = Task { await self.pumpClaudeCode(process, activation: activationID) }
    live.claude.activation = activation
    return activation
  }

  private func pumpClaudeCode(_ process: ClaudeCodeProcess, activation: UUID) async {
    async let ending = process.run()
    for await frame in process.frames {
      await ingest(frame, activation: activation)
    }
    await claudeCodeEnded(activation: activation, how: await ending)
  }

  private func isCurrent(_ activation: UUID) -> Bool {
    guard case let .claudeCode(claude)? = liveState?.engine else { return false }
    return claude.activation?.id == activation
  }

  private func ingest(_ frame: ClaudeStreamFrame, activation: UUID) async {
    guard isCurrent(activation), !Task.isCancelled else { return }
    do {
      switch frame {
      case let .transcriptMirror(entries):
        let pending = live.claude.handover?.outstanding
        let confirmed = try await repo.appendClaudeCodeMirror(entries, confirming: pending)
        guard isCurrent(activation) else { return }
        if let error = entries.last(where: { $0["isApiErrorMessage"] == .bool(true) }).flatMap(apiErrorText) {
          live.claude.apiError = error
        }
        guard let handover = pending, confirmed != nil else { return }
        let turnOver = !live.claude.turnRunning
        try modify {
          if let through = handover.through {
            $0.queueTail = max($0.queueTail, through)
            $0.queueHead = max($0.queueHead, $0.queueTail)
          }
          guard $0.claude.handover?.at == handover.at else { return }
          $0.claude.handover = nil
          $0.claude.backstop?.cancel()
          $0.claude.backstop = nil
        }
        if turnOver {
          try await repo.settleClaudeCodeTurn()
          nudge()
        }
      case let .result(result) where live.claude.compacting:
        live.claude.compacting = false
        if result.isError {
          Logger(label: "wuhu.loop").warning("Claude Code could not compact", metadata: [
            "session": "\(id.rawValue)", "reason": "\(result.text ?? "\(result.outcome)")",
          ])
        }
        nudge()
      case let .result(result):
        if let at = live.claude.handover?.at {
          let wait = claudeCodeHandoverBackstop
          live.claude.backstop = Task { [clock] in
            guard (try? await clock.sleep(for: wait)) != nil else { return }
            await self.handoverBackstopRanOut(handedOverAt: at, activation: activation)
          }
        }
        try modify {
          $0.claude.turnRunning = false
          $0.claude.turnStartedAt = nil
          $0.claude.evaluate = true
          $0.claude.contextTokens = result.usage?.contextTokens ?? $0.claude.contextTokens
        }
        guard !result.isError else {
          await markErrored(error: ClaudeCodeTurnFailed(outcome: result.outcome, reason: result.text ?? live.claude.apiError))
          return
        }
        try modify { $0.claude.cutOffs = 0 }
        try await repo.settleClaudeCodeTurn()
        nudge()
      case let .malformed(value):
        abandonActivation()
        await markErrored(error: ClaudeCodeMalformedFrame(frame: value))
      case let .undecodable(bytes):
        Logger(label: "wuhu.loop").warning("Claude Code printed a line that is not JSON", metadata: [
          "session": "\(id.rawValue)", "line": "\(String(decoding: bytes.prefix(512), as: UTF8.self))",
        ])
      case .compactBoundary:
        // Known again at the next result.
        live.claude.contextTokens = nil
      case .initialization, .rateLimit, .other:
        break
      }
    } catch is CancellationError {
    } catch {
      abandonActivation()
      await markErrored(error: error)
    }
  }

  private func handoverBackstopRanOut(handedOverAt at: Date, activation: UUID) {
    guard isCurrent(activation), !live.claude.turnRunning, live.claude.handover?.at == at else { return }
    Logger(label: "wuhu.loop").warning("Claude Code never recorded a handover after its turn ended; it goes again", metadata: [
      "session": "\(id.rawValue)",
    ])
    live.claude.handover = nil
    live.claude.backstop = nil
    nudge()
  }

  private func claudeCodeEnded(activation: UUID, how: String) async {
    guard isCurrent(activation) else { return }
    let claude = live.claude
    live.claude.activation = nil
    live.claude.handover = nil
    live.claude.backstop?.cancel()
    live.claude.backstop = nil
    live.claude.turnRunning = false
    live.claude.turnStartedAt = nil
    live.claude.stopping = false
    live.claude.compacting = false
    guard claude.turnRunning, !claude.stopping else {
      if live.queueHead > live.queueTail || live.claude.continuation != nil || live.claude.evaluate { nudge() }
      return
    }
    Logger(label: "wuhu.loop").notice("Claude Code exited mid-turn", metadata: [
      "session": "\(id.rawValue)", "how": "\(how)",
    ])
    live.claude.cutOffs += 1
    live.claude.continuation = .exited(how)
    nudge()
  }

  // Waits for the pump, so every frame the process printed is stored first.
  func stopClaudeCodeActivation(continuing reason: ClaudeCodeLive.Continuation?) async {
    guard case let .claudeCode(claude)? = liveState?.engine, let activation = claude.activation else { return }
    if claude.turnRunning, let reason { live.claude.continuation = reason }
    live.claude.stopping = true
    activation.process.kill()
    await activation.pump?.value
  }

  // Ended by us over a broken stream: the session errors, and its exit is no cut-off.
  private func abandonActivation() {
    guard let activation = liveState.flatMap({ state -> ClaudeCodeLive.Activation? in
      guard case let .claudeCode(claude) = state.engine else { return nil }
      return claude.activation
    }) else { return }
    live.claude.stopping = true
    activation.process.kill()
  }

  func endIdleActivation() {
    guard let activation = live.claude.activation, !live.claude.turnRunning else { return }
    live.claude.stopping = true
    activation.process.kill()
  }

  func claudeCodeHook(_ hook: ClaudeCodeHook, activation: UUID) async -> JSONValue {
    let context = await deliveredContext(hook)
    let nothing = hook.reply(handingOver: context)
    guard isCurrent(activation), case .healthy = live.sessionStatus,
          live.claude.turnRunning, !live.claude.stopping, live.claude.handover == nil
    else { return nothing }
    if case .endOfTurn(reentered: true) = hook { return nothing }
    let at = date()
    live.claude.handover = .rendering(at: at)
    let startedAt = live.claude.turnStartedAt
    var text: String?
    var through: Int?
    var nag: Nag?
    var notice = false
    var armed: [ArmedSubscription] = []
    do {
      notice = try await repo.claudeCodeOwedCompactionNotice() != nil
      if notice { armed = try await repo.armedSubscriptions() }
      let entries = try await repo.undrainedInputs()
      if !entries.isEmpty {
        let blocks = try await loopConfig.claudeCode.render(id, entries.map(\.input), .hook)
        text = blocks.compactMap { block in
          if case let .text(text) = block { text } else { nil }
        }.joined(separator: "\n\n")
        through = entries.last?.id
      } else if case .endOfTurn = hook {
        // The gate: this turn's tool results may not be stored yet, so the
        // receipts recorded since its handover count too.
        nag = try await repo.claudeCodeEnvironment(pendingSince: startedAt).nag(task: live.isTask, now: date())
        text = nag?.rendered(at: date())
      }
    } catch {
      Logger(label: "wuhu.loop").warning("Claude Code hook could not render its handover", metadata: [
        "session": "\(id.rawValue)", "error": "\(error)",
      ])
      text = nil
      through = nil
      nag = nil
      notice = false
    }
    if notice {
      text = [compactionNotice(armed), text].compactMap(\.self).joined(separator: "\n\n")
    }
    guard isCurrent(activation), case .rendering? = live.claude.handover else { return nothing }
    guard let text, through != nil || nag != nil || notice else {
      live.claude.handover = nil
      return nothing
    }
    live.claude.handover = .outstanding(.init(record: hook.record, through: through, note: false, nag: nag, compactionNotice: notice, at: at))
    return hook.reply(handingOver: [context, text].compactMap(\.self).joined(separator: "\n\n"))
  }

  private func deliveredContext(_ hook: ClaudeCodeHook) async -> String? {
    guard case let .afterTool(toolUseID, _) = hook else { return nil }
    do {
      return try await repo.scopeContext(ToolCallID(toolUseID))?.rendered(at: date())
    } catch {
      Logger(label: "wuhu.loop").warning("Claude Code hook could not read its tool call's context", metadata: [
        "session": "\(id.rawValue)", "error": "\(error)",
      ])
      return nil
    }
  }

  var claudeCodeContextTokens: Int? {
    guard case let .claudeCode(claude)? = liveState?.engine else { return nil }
    return claude.contextTokens
  }
}

struct ClaudeCodeTurnFailed: Error, CustomStringConvertible {
  var outcome: ClaudeStreamFrame.TurnResult.Outcome
  var reason: String?

  var description: String {
    guard let reason, !reason.isEmpty else { return "Claude Code ended the turn with an error (\(outcome))" }
    return "Claude Code ended the turn with an error: \(reason)"
  }
}

private func apiErrorText(_ entry: OrderedDictionary<String, JSONValue>) -> String? {
  entry["message"]?.object?["content"]?.array?.compactMap { $0.object?["text"]?.stringValue }.joined(separator: "\n")
}

struct ClaudeCodeMalformedFrame: Error, CustomStringConvertible {
  var frame: JSONValue
  var description: String { "Claude Code sent a frame Wuhu cannot read: \(frame.jsonString().prefix(512))" }
}

struct ClaudeCodeCutOff: Error, CustomStringConvertible {
  var count: Int
  var last: ClaudeCodeLive.Continuation
  var description: String {
    "Claude Code ended \(count) turns in a row before they finished; the last time \(last.reason)"
  }
}

private func quoted(_ text: String) -> String {
  "\"" + text.split(whereSeparator: \.isNewline).joined(separator: " ") + "\""
}
