import SessionDomain
import struct SpaceCore.SessionHydration
import enum SpaceCore.SessionMail
import struct SpaceCore.SessionPut
import struct SpaceCore.SessionRecord
import struct SpaceCore.SessionRows
import enum WuhuAI.ContentBlock
import enum WuhuAI.InferenceError
import struct WuhuAI.ToolCall
import Wuwei
#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif

/// A session's loop as a cell over the session tables. Its only state is theirs: what the session works on is the job at the transcript's end, if there is one (``Slot``). Every message reads the session, applies what it brings, and advances it: drains, nags and kernel tools are written at once; an inference step, a tool call or a compaction is started as a job, which answers by mail. A job's answer for a slot the transcript has left is dropped.
@Cell
struct SessionCell {
  static let kind = SessionMail.kind
  static let schema = [
    "CREATE TABLE session_state (\(ownerColumn), generation INTEGER NOT NULL, position INTEGER NOT NULL, turn TEXT NOT NULL, reestablish TEXT NOT NULL, replied INTEGER NOT NULL, UNIQUE (owner))",
    "ALTER TABLE session_state ADD COLUMN nags TEXT",
    "ALTER TABLE session_state ADD COLUMN seen INTEGER",
    "CREATE TABLE session_seen (\(ownerColumn), kind TEXT NOT NULL, key TEXT NOT NULL, value TEXT, UNIQUE (owner, kind, key))",
  ]

  /// An input for the queue. Looking at it is a step of its own, so the input stays whatever that step meets.
  mutating func put(_ put: SessionPut) throws {
    try rows.put(id.session, put)
    ctx.send(id).look()
  }

  /// Takes back the input on `topic` that the model has not seen.
  mutating func clear(_ topic: String) throws {
    try rows.clear(id.session, topic: topic)
    ctx.send(id).look()
  }

  /// The queue changed, or a command is pending.
  mutating func look() throws {
    if let work = working(try load()) { try yield(work) }
    try advance()
  }

  /// A delayed input came due, or a parked model's reminder.
  mutating func wake() throws {
    try look()
  }

  /// When the next delayed input comes due or a model that stopped with requests open is next reminded of them.
  func nextWake() -> Instant? {
    guard let due = [try! rows.nextDue(id.session), try! parkWake()].compactMap(\.self).min() else { return nil }
    return Instant(milliseconds: Int64((due.timeIntervalSince1970 * 1000).rounded(.up)))
  }

  /// What `advance` leaves a parked model with: its next reminder, unless something else will wake it.
  private func parkWake() throws -> Date? {
    let session = try load()
    let transcript = session.transcript
    guard !session.stopped, working(session) == nil, session.queueHead == session.queueTail, !transcript.hasWork,
          transcript.nextPendingToolCall == nil, case .assistant? = transcript.items.last
    else { return nil }
    if case .foldPending = transcript.phase { return nil }
    return transcript.environment.nextTimer(openRequests: try rows.openRequests(id.session), now: client.dueNow())
  }

  /// Stops the job the session works on and nothing else: main has marked the session errored.
  mutating func cancel() throws {
    stop(working(try load()))
  }

  mutating func retitle(_ title: String) throws {
    try rows.retitle(id.session, title)
  }

  mutating func retag(_ tags: [String]) throws {
    try rows.retag(id.session, tags)
  }

  /// The step at hand yields to it if it can; the forced step runs next.
  mutating func compact(_ instructions: String?) throws {
    try rows.requestCommand(id.session, .compact(instructions: instructions))
    try look()
  }

  mutating func interrupt() throws {
    let session = try load()
    guard !session.stopped else { return }
    try rows.markInterrupted(id.session)
    stop(working(session))
  }

  mutating func resume() throws {
    let record = try load().record
    guard record.hold == .interrupted || record.work == .errored else { return }
    try rows.markResumed(id.session)
    try advance()
  }

  /// A session archived mid-job comes back interrupted: unarchiving it does not restart the work. Its streams end.
  mutating func archive(_ grace: Duration) throws {
    let session = try load()
    guard session.record.lifecycle == .live else { return }
    if let work = working(session) {
      stop(work)
      try rows.markInterrupted(id.session)
    }
    for stream in try rows.streams(id.session) {
      unstream(stream)
    }
    try rows.archive(id.session, grace: grace)
    invalidateInference()
  }

  mutating func unarchive() throws {
    try rows.unarchive(id.session)
    invalidateInference()
    try advance()
  }

  /// Start over. Main checked the session was settled; one that started a job since keeps it, and the restart is dropped. Queued input waits for the new generation.
  mutating func restart(_ executor: SessionExecutor?, _ route: SessionModelRoute?, _ note: String?, _ runningWork: [String]) throws {
    if let session = try? load(), working(session) != nil { return }
    let restart = try client.dependencies.yield {
      try rows.restart(id.session, executor: executor, note: note, modelRoute: route, runningWork: runningWork, uuid: client.uuid)
    }
    try write(SessionTurn(generation: restart.generation, position: 1, turn: .inert, reestablish: [], replied: false, nags: nil, seen: true))
    try db.execute(Seen.delete())
    invalidateInference()
    try advance()
  }

  mutating func stream(_ subscription: SubscriptionID, _ url: URL, _ throttle: Double) {
    ctx.create(streamJob(subscription), params: .init(dialer: .session(id.session), session: id.session, subscription: subscription, url: url, throttle: throttle, owner: id.recipient.retyped()))
  }

  mutating func unstream(_ subscription: SubscriptionID) {
    guard ctx.exists(streamJob(subscription)) else { return }
    ctx.send(.stop, to: streamJob(subscription))
  }

  /// An archived session ends the stream instead of taking the event.
  mutating func streamed(_ batch: StreamBatch) throws {
    guard try load().record.lifecycle == .live else {
      if batch.ending == nil { ctx.send(.stop, to: batch.job) }
      return
    }
    try rows.observed(id.session, stream: batch.subscription, url: batch.url, text: batch.text, throttle: batch.throttle, ends: batch.ending != nil, uuid: client.uuid)
    if batch.ending == nil { ctx.send(.acked, to: batch.job) }
    try look()
  }

  mutating func stepped(_ step: InferenceJob.ID, _ result: StepResult) throws {
    let session = try load()
    guard session.record.lifecycle == .live else { return }
    let forced = step == session.slot.step(forced: true)
    guard forced || step == session.slot.step(forced: false) else { return }
    switch result.ending {
    case let .reply(entry, fullness):
      var transcript = session.transcript
      transcript.append(.assistant(entry))
      // The model tried to finish. A nag due now is written with its message,
      // so the session never reads settled while it owes one.
      let now = client.now()
      if !forced, entry.toolCalls.isEmpty, let nag = transcript.environment.nag(task: session.isTask, openRequests: try rows.openRequests(id.session), now: client.dueNow()) {
        transcript.append(.notification(nag.notification(id: client.uuid(), at: now)))
      }
      let appended = Array(transcript.items[session.slot.position...])
      try rows.append(id.session, items: appended, inputOrigin: transcript.cacheWarmingInputOrigin, completingCompact: forced)
      try move(wrote: appended) {
        $0.reply(entry.toolCalls)
        $0.input(appended.count - 1)
      }
      let next = Slot(session.slot, position: transcript.items.count)
      if forced, !entry.callsCompact {
        start(next.compaction, .fallback)
        return
      }
      // A step checks the hard threshold before it infers; a model that stopped past it is compacted before anything else.
      if !forced, entry.toolCalls.isEmpty, fullness >= client.config.thresholds.hard {
        try rows.markCompacting(id.session, active: true)
        start(next.step(forced: true), .forcedCompact)
        return
      }
    case .cancelled:
      break
    case let .full(fullness):
      if fullness >= client.config.thresholds.hard {
        try rows.markCompacting(id.session, active: true)
        start(session.slot.step(forced: true), .forcedCompact)
        return
      }
      try append(session, [.notification(.init(
        id: client.uuid(),
        timestamp: client.now(),
        kind: .context,
        subscriptionID: SubscriptionID("context-pressure"),
        content: .init(text: """
        <compaction-notice>
        Context is \(Int((fullness * 100).rounded()))% full. Compact at a natural boundary of your choosing: \
        call bookmark to mark a cut point, then compact to fold everything before it.
        </compaction-notice>
        """),
      ))]) { $0.input(1) }
    case .compact:
      start(session.slot.compaction, .fallback)
      return
    case let .requestTooLarge(limit, failure):
      // A generation that never replied was just made: a fresh compaction did not make the request fit.
      guard session.generation == 0 || session.transcript.hasFreshReply else {
        try rows.markErrored(id.session, message: limit.map { String(describing: InferenceError.requestTooLargeAfterCompaction(limitBytes: $0)) } ?? failure)
        return
      }
      start(session.slot.compaction, .fallback)
      return
    case let .handoff(binding, budget):
      start(session.slot.compaction, .handoff(binding, budget))
      return
    case let .roster(notice):
      try append(session, [.notification(.init(
        id: client.uuid(), timestamp: client.now(), kind: .context, subscriptionID: ToolRosterChanged.source, content: .init(text: notice),
      ))]) { $0.input(1) }
    case let .parked(failure):
      try rows.markErrored(id.session, message: failure)
      return
    }
    try advance()
  }

  mutating func called(_ call: ToolCallJob.ID, _ answer: ToolCallAnswer) throws {
    let session = try load()
    guard session.record.lifecycle == .live, call == session.slot.call else { return }
    let provenance: ToolResultItem.Provenance = session.transcript.nextPendingToolCall.map { .toolCall(ToolCallID($0.id)) } ?? .compactionReestablishment
    switch answer {
    case let .result(payload, context): try writeToolResult(session, provenance, payload, context: context)
    case .interrupted: try writeToolResult(session, provenance, .failure(.init(message: interruptedToolMessage)))
    }
    try advance()
  }

  mutating func compacted(_ compaction: CompactionJob.ID, _ answer: CompactionAnswer) throws {
    let session = try load()
    guard session.record.lifecycle == .live, compaction == session.slot.compaction else { return }
    switch answer {
    case let .folded(head, kept, transition, call):
      let closing = call.flatMap { call in
        session.transcript.phase == .live ? ToolResultItem(id: client.uuid(), timestamp: client.now(), provenance: .toolCall(call), payload: .compact(.init(summary: head.summary))) : nil
      }
      let written = try rows.writeCompaction(id.session, closing: closing, head: head, kept: kept, completingCompact: true, transition: transition)
      try write(SessionTurn(generation: session.generation + 1, position: written.items.count, turn: .model, reestablish: written.reestablishments, replied: false, nags: carried(into: written), seen: true))
      try see(only: written)
      invalidateInference()
    case let .refused(call, message):
      try writeToolResult(session, .toolCall(call), .failure(.init(message: message)))
    case let .handoff(transcript):
      let written = try rows.writePortableHandoff(id.session, transcript: transcript)
      try write(SessionTurn(generation: session.generation + 1, position: written.items.count, turn: .model, reestablish: written.reestablishments, replied: false, nags: carried(into: written), seen: true))
      try see(only: written)
      invalidateInference()
    case let .failed(message):
      try rows.markErrored(id.session, message: message)
      return
    }
    try advance()
  }

  /// Takes every step that writes at once, until one needs a job or there is nothing to do.
  private mutating func advance() throws {
    while true {
      let session = try load()
      try check(session)
      guard !session.stopped, working(session) == nil, try next(session) else { return }
    }
  }

  /// The session's next step; true when it was written and there may be another.
  private mutating func next(_ session: SessionState) throws -> Bool {
    let transcript = session.transcript
    // A pending fold has no work, nags or forced compaction, and a compact
    // request finds it compacted already: only a delivery runs the fold.
    if case let .foldPending(call) = transcript.phase {
      try rows.takeCommand(id.session)
      if session.queueHead > session.queueTail { start(session.slot.compaction, .fold(call)) }
      return false
    }
    if let call = transcript.nextPendingToolCall { return try run(call, session) }
    if session.queueHead > session.queueTail {
      let drained = try rows.drainQueue(id.session)
      try move(wrote: drained.items) { $0.input(drained.items.count) }
      return true
    }
    if let written = try rows.materializeCompactRequest(id.session, uuid: client.uuid) {
      try move { $0.input(written) }
      try rows.markCompacting(id.session, active: true)
      start(try load().slot.step(forced: true), .forcedCompact)
      return false
    }
    if transcript.hasWork {
      if let call = transcript.reestablishments.first {
        try start(session.slot.call, call)
      } else {
        start(session.slot.step(forced: false), .normal)
      }
      return false
    }
    // Only a model that stopped is asked whether it may; a generation that never
    // ran (created, restarted) is inert. What is left is a park wake (`nextWake`).
    guard case .assistant? = transcript.items.last else { return false }
    let openRequests = try rows.openRequests(id.session)
    let now = client.now()
    if let nag = transcript.environment.nag(task: session.isTask, openRequests: openRequests, now: client.dueNow()) {
      try append(session, [.notification(nag.notification(id: client.uuid(), at: now))]) { $0.input(1) }
      return true
    }
    return false
  }

  private mutating func run(_ call: ToolCall, _ session: SessionState) throws -> Bool {
    let callID = ToolCallID(call.id)
    switch KernelTool(rawValue: call.name) {
    case .bookmark:
      do {
        let arguments = try decodeArguments(BookmarkArguments.self, from: call)
        try append(session, [.bookmark(BookmarkMarker(id: client.uuid(), timestamp: client.now(), name: arguments.name, toolCallID: callID))]) { $0.answer(callID) }
      } catch {
        try writeToolResult(session, .toolCall(callID), .failure(.init(message: "invalid bookmark arguments: \(error)")))
      }
      return true
    case .compact:
      let arguments: CompactArguments
      do {
        arguments = try decodeArguments(CompactArguments.self, from: call)
        _ = try session.transcript.compactKeptRange(callID: callID, bookmark: arguments.bookmark)
      } catch let notFound as BookmarkNotFound {
        try writeToolResult(session, .toolCall(callID), .failure(.init(message: "bookmark \"\(notFound.name)\" not found; name an existing bookmark or omit it to fold everything")))
        return true
      } catch {
        try writeToolResult(session, .toolCall(callID), .failure(.init(message: "invalid compact arguments: \(error)")))
        return true
      }
      guard arguments.park else {
        start(session.slot.compaction, .fold(callID))
        return false
      }
      if let refusal = ParkRefusal(session.transcript.environment, task: session.isTask, openRequests: try rows.openRequests(id.session)) {
        try writeToolResult(session, .toolCall(callID), .failure(.init(message: refusal.description)))
      } else {
        try writeToolResult(session, .toolCall(callID), .compact(.init(summary: arguments.summary)))
      }
      return true
    case nil:
      try start(session.slot.call, call)
      return false
    }
  }

  private func streamJob(_ subscription: SubscriptionID) -> StreamJob.ID {
    .init("\(id.session.rawValue):\(subscription.rawValue)")
  }

  private func load() throws -> SessionState {
    SessionState(try rows.hydrate(id.session))
  }

  /// The job the session works on: one at its transcript's end that has not ended, or has ended with something still to write. A step that was cancelled or parked has nothing.
  private func working(_ session: SessionState) -> Slot.Work? {
    session.slot.working(exists: { work in
      switch work {
      case let .step(id): ctx.exists(id)
      case let .call(id): ctx.exists(id)
      case let .compaction(id): ctx.exists(id)
      }
    }, outcome: { ctx.job($0).outcome() })
  }

  /// Tells the work at hand when to give the turn back to the input that waits: a step at once for a pending compact command. A forced step and a compaction never yield.
  private mutating func yield(_ work: Slot.Work) throws {
    switch work {
    case let .step(step) where !step.key.hasSuffix(forcedSuffix):
      let by = try rows.pendingCommand(id.session) != nil ? client.now() : try rows.yieldDeadline(id.session)
      if let by { ctx.send(.yield(by: by), to: step) }
    case let .call(call):
      if let by = try rows.yieldDeadline(id.session) { ctx.send(.yield(by: by), to: call) }
    case .step, .compaction:
      break
    }
  }

  private mutating func stop(_ work: Slot.Work?) {
    switch work {
    case let .step(step)?: ctx.send(.interrupt, to: step)
    case let .call(call)?: ctx.send(.interrupt, to: call)
    case .compaction?, nil: break
    }
  }

  private mutating func start(_ step: InferenceJob.ID, _ mode: InferenceMode) {
    let slot = Slot(step)
    ctx.create(step, params: .init(session: id.session, generation: slot.generation, position: slot.position, mode: mode))
  }

  private mutating func start(_ call: ToolCallJob.ID, _ toolCall: ToolCall) throws {
    let slot = Slot(call)
    ctx.create(call, params: .init(session: id.session, generation: slot.generation, position: slot.position, call: toolCall, yieldBy: try rows.yieldDeadline(id.session)))
  }

  private mutating func start(_ compaction: CompactionJob.ID, _ kind: CompactionJob.Kind) {
    let slot = Slot(compaction)
    ctx.create(compaction, params: .init(session: id.session, generation: slot.generation, position: slot.position, kind: kind))
  }

  private mutating func writeToolResult(_ session: SessionState, _ provenance: ToolResultItem.Provenance, _ payload: ToolResultPayload, context: ScopeContext? = nil) throws {
    // The backstop, not the budget: whatever the tool layer missed must not
    // enter the transcript unclamped.
    var items: [TranscriptItem] = [.toolResult(ToolResultItem(id: client.uuid(), timestamp: client.now(), provenance: provenance, payload: payload.clamped()))]
    if let context { items.append(.notification(context.notice(id: client.uuid(), at: client.now()))) }
    try append(session, items) { turn in
      switch (provenance, payload) {
      case let (.toolCall(call), .compact): turn.park(call)
      case let (.toolCall(call), _): turn.answer(call)
      case (.compactionReestablishment, _): turn.reestablished()
      }
      turn.input(context == nil ? 0 : 1)
    }
  }

  private mutating func append(_ session: SessionState, _ items: [TranscriptItem], _ change: (inout SessionTurn) -> Void) throws {
    var transcript = session.transcript
    for item in items { transcript.append(item) }
    try rows.append(id.session, items: items, inputOrigin: transcript.cacheWarmingInputOrigin)
    try move(wrote: items, change)
  }

  /// A session that has no turn row yet gets one from its transcript at its next step (`check`).
  private mutating func move(wrote items: [TranscriptItem] = [], _ change: (inout SessionTurn) -> Void) throws {
    guard var turn = db.rows(SessionTurn.all).first else { return }
    change(&turn)
    for item in items { turn.nags?.apply(item) }
    try write(turn)
    if turn.seen == true { try see(items) }
  }

  /// A file or a folder is seen as it was last; an instruction text keeps the path it first came from.
  private mutating func see(_ items: some Sequence<TranscriptItem>) throws {
    for item in items {
      for seen in try Seen.of(item) {
        if seen.kind == .text, !db.rows(seen.earlier).isEmpty { continue }
        try db.execute(seen.earlier.delete())
        try db.execute(Seen.insert { seen })
      }
    }
  }

  /// A new generation has seen the files its kept tail read or wrote; folders and instruction texts are shown to it again.
  private mutating func see(only generation: Transcript) throws {
    try db.execute(Seen.delete())
    try see(generation.items.filter { if case .toolResult = $0 { true } else { false } })
  }

  /// A fold leaves what the session owes as it is.
  private func carried(into generation: Transcript) -> NagState? {
    db.rows(SessionTurn.all).first?.nags.map { NagState(settle: $0.settle, kept: generation.items) }
  }

  private mutating func write(_ turn: SessionTurn) throws {
    try db.execute(SessionTurn.delete())
    try db.execute(SessionTurn.insert { turn })
  }

  /// A turn row that is not what the transcript folds to is reported and replaced, so each divergence is reported once.
  private mutating func check(_ session: SessionState) throws {
    let environment = session.transcript.environment
    let folded = SessionTurn(folding: session.transcript, generation: session.generation, nags: environment.nags)
    let row = db.rows(SessionTurn.all).first
    if row != folded { try write(folded) }
    var stored = row
    if stored?.nags == nil { stored?.nags = folded.nags }
    stored?.seen = true
    if let stored, stored != folded { report(.turn(stored), .turn(folded)) }

    let (seen, shown) = (Set(db.rows(Seen.all)), try Seen.folding(environment.tools))
    guard seen != shown else { return }
    try db.execute(Seen.delete())
    for seen in shown { try db.execute(Seen.insert { seen }) }
    if row?.seen == true { report(.seen(seen.subtracting(shown).sorted { $0.key < $1.key }), .seen(shown.subtracting(seen).sorted { $0.key < $1.key })) }
  }

  private mutating func report(_ stored: TurnDifference.Side, _ folded: TurnDifference.Side) {
    guard let report = client.config.turnDifference else { return }
    let difference = TurnDifference(time: client.now().formatted(.iso8601), session: id.key, stored: stored, folded: folded)
    ctx.emit { await report(difference) }
  }

  private mutating func invalidateInference() {
    let (session, invalidate) = (id.session, client.config.invalidateInference)
    ctx.emit { await invalidate(session) }
  }

  private var rows: SessionRows {
    SessionRows(host: db.host, store: client.store)
  }

  private var client: LoopClient {
    ctx.dependency(LoopClient.self)
  }
}

/// A session as one message of its cell finds it.
struct SessionState {
  let record: SessionRecord
  let generation: Int
  let transcript: Transcript
  let queueHead: Int
  let queueTail: Int
  let slot: Slot

  init(_ hydration: SessionHydration) {
    record = hydration.record
    generation = hydration.generation
    transcript = switch hydration.transcript { case let .kernel(transcript): transcript }
    queueHead = hydration.queueHead
    queueTail = hydration.queueTail
    slot = Slot(session: hydration.record.id, generation: hydration.generation, position: transcript.items.count, stepTry: hydration.stepTry)
  }

  var isTask: Bool { record.kind == .task }
  var stopped: Bool { record.stopped }

  /// Nothing to do, now or once its job answers: what an archive or a restart waits for.
  var settled: Bool { stopped || (queueHead == queueTail && !transcript.hasWork) }
}

/// The transcript's end, which names every job that can answer there: `<session>:<generation>:<position>` for a tool call and a compaction, plus `:<resumes>` for a step and `:compact` for a forced one.
struct Slot {
  let session: SessionID
  let generation: Int
  let position: Int
  let stepTry: Int

  init(session: SessionID, generation: Int, position: Int, stepTry: Int) {
    self.session = session
    self.generation = generation
    self.position = position
    self.stepTry = stepTry
  }

  init(_ slot: Slot, position: Int) {
    self.init(session: slot.session, generation: slot.generation, position: position, stepTry: slot.stepTry)
  }

  init<J: Job>(_ job: Address<J>) {
    let parts = job.key.split(separator: ":")
    self.init(session: SessionID(String(parts[0])), generation: Int(parts[1])!, position: Int(parts[2])!, stepTry: parts.count > 3 ? Int(parts[3])! : 0)
  }

  private var key: String { "\(session.rawValue):\(generation):\(position)" }

  func step(forced: Bool) -> InferenceJob.ID { .init("\(key):\(stepTry)\(forced ? forcedSuffix : "")") }
  var call: ToolCallJob.ID { .init(key) }
  var compaction: CompactionJob.ID { .init(key) }

  enum Work {
    case step(InferenceJob.ID), call(ToolCallJob.ID), compaction(CompactionJob.ID)
  }

  func working(exists: (Work) -> Bool, outcome: (InferenceJob.ID) -> StepResult?) -> Work? {
    if exists(.compaction(compaction)) { return .compaction(compaction) }
    for forced in [true, false] {
      let step = step(forced: forced)
      guard exists(.step(step)) else { continue }
      switch outcome(step)?.ending {
      case .cancelled?, .parked?: return nil
      default: return .step(step)
      }
    }
    return exists(.call(call)) ? .call(call) : nil
  }
}

private let forcedSuffix = ":compact"

/// How the session tables write their times.
let queueDate = Date.ISO8601FormatStyle(includingFractionalSeconds: true)

let interruptedToolMessage = """
Tool execution was interrupted by the user. It may have partially run; \
it will not be retried automatically.
"""

extension SessionRecord {
  /// Nothing runs it: held, errored, archived, or left from an executor this build no longer has.
  var stopped: Bool { hold == .interrupted || work == .errored || lifecycle != .live || executor.isRetired }
}

extension Address where Target == SessionCell {
  var session: SessionID { SessionID(key) }
}

extension Transcript {
  var hasFreshReply: Bool {
    items[keptCount...].contains { if case .assistant = $0 { true } else { false } }
  }

  /// The generation head's re-establishing reads that are not answered, while the generation has none of its own replies.
  var reestablishments: [ToolCall] {
    guard needsReestablishment, case let .generationHead(head) = items.first else { return [] }
    let done = items[keptCount...].count { item in
      if case let .toolResult(result) = item, result.provenance == .compactionReestablishment { true } else { false }
    }
    return Array(head.reestablishmentCalls.dropFirst(done))
  }
}

extension AssistantEntry {
  fileprivate var callsCompact: Bool {
    content.contains { block in
      guard case let .toolCall(call) = block else { return false }
      return call.name == KernelTool.compact.rawValue
    }
  }
}
