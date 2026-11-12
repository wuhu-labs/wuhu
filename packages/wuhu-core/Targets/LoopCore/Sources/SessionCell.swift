import func MainHub.renderedRows
import struct MainHub.ToolProblem
import SessionDomain
import SessionTools
import struct SpaceCore.ArmedSubscription
import enum SpaceCore.ObservationMail
import struct SpaceCore.ObservationSlot
import enum SpaceCore.Observed
import struct SpaceCore.Rows
import struct SpaceCore.SessionHydration
import enum SpaceCore.SessionMail
import struct SpaceCore.SessionPut
import struct SpaceCore.SessionRecord
import struct SpaceCore.SessionRows
import StructuredQueries
import enum WuhuAI.ContentBlock
import enum WuhuAI.InferenceError
import struct WuhuAI.ToolCall
import Wuwei
#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif

/// A session's durable turn over lines and its owned rows. Each message advances until work needs a job; answers for a slot the turn has left are dropped.
@Cell
struct SessionCell {
  static let kind = SessionMail.kind
  static let schema = [
    "CREATE TABLE session_state (\(ownerColumn), generation INTEGER NOT NULL, position INTEGER NOT NULL, turn TEXT NOT NULL, reestablish TEXT NOT NULL, replied INTEGER NOT NULL, UNIQUE (owner))",
    "ALTER TABLE session_state ADD COLUMN nags TEXT",
    "ALTER TABLE session_state ADD COLUMN seen INTEGER",
    "CREATE TABLE session_seen (\(ownerColumn), kind TEXT NOT NULL, key TEXT NOT NULL, value TEXT, UNIQUE (owner, kind, key))",
    "ALTER TABLE session_state ADD COLUMN armed INTEGER",
    "CREATE TABLE session_armed (\(ownerColumn), id TEXT NOT NULL, slot TEXT NOT NULL, handler INTEGER NOT NULL, UNIQUE (owner, id))",
    "ALTER TABLE session_state ADD COLUMN compact TEXT",
    "ALTER TABLE session_state DROP COLUMN compact",
    "ALTER TABLE session_state ADD COLUMN held TEXT",
    "ALTER TABLE session_state ADD COLUMN binding TEXT",
    "ALTER TABLE session_state ADD COLUMN bookmarks TEXT",
    "ALTER TABLE session_state ADD COLUMN origin INTEGER",
    "ALTER TABLE session_seen ADD COLUMN position INTEGER",
    "ALTER TABLE session_state ADD COLUMN warming TEXT",
    "CREATE TABLE session_scripts (\(ownerColumn), handle TEXT NOT NULL, slot TEXT NOT NULL, UNIQUE(owner, handle))",
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

  /// The queue changed.
  mutating func look() throws {
    if let work = working(try load()) { try yield(work) }
    try advance()
  }

  mutating func rewatch() throws {
    for watched in try rows.plainSQLObservations(id.session) {
      ctx.send(.watch(watched.watch(recipient: id.recipient.retyped())), to: ObservationMail.recipient)
    }
  }

  /// A delayed input came due, a parked model's reminder, or a warming wake.
  mutating func wake() throws {
    try look()
    try ping()
  }

  /// When the next delayed input comes due, a model that stopped with requests open is next reminded of them, or the next ping.
  func nextWake() -> Instant? {
    guard let due = [try! rows.nextDue(id.session), try! parkWake(), warmingWake()].compactMap(\.self).min() else { return nil }
    return Instant(milliseconds: Int64((due.timeIntervalSince1970 * 1000).rounded(.up)))
  }

  /// When warming's next ping is due, while a reply's schedule holds. A ping in flight owns the schedule until its reply: no wake arms under it, so the next one counts from that reply.
  private func warmingWake() -> Date? {
    guard let turn = turn(), let warming = turn.warming else { return nil }
    guard turn.turn == .idle || turn.origin != true else { return nil }
    return Date(timeIntervalSinceReferenceDate: warming.repliedAt).addingTimeInterval(Double(warming.schedule.intervalSeconds))
  }

  /// The warming wake, once due: a ping at the last reply plus the interval. A ping is an ordinary inference, unless the schedule ran out or nothing is left to warm — then warming ends.
  private mutating func ping() throws {
    guard let warming = turn()?.warming else { return }
    let now = client.now()
    let dueNow = client.dueNow()
    let replied = Date(timeIntervalSinceReferenceDate: warming.repliedAt)
    guard dueNow >= replied.addingTimeInterval(Double(warming.schedule.intervalSeconds)) else { return }
    let session = try load()
    guard dueNow < replied.addingTimeInterval(Double(warming.schedule.lifetimeSeconds)), warming.pings < warming.schedule.maxPings,
          session.record.lifecycle == .live, session.record.hold == .normal, session.record.work == .noWork,
          working(session) == nil, try rows.lastLineRole(id.session) == .assistant
    else { return try endWarming(session.turn) }
    try append(session, [.notification(.cacheWarming(id: client.uuid(), at: now))]) { $0.pinged() }
    try advance()
  }

  private mutating func endWarming(_ turn: SessionTurn) throws {
    var turn = turn
    turn.warming = nil
    try write(turn)
  }

  /// What `advance` leaves a parked model with: its next reminder, unless something else will wake it.
  private func parkWake() throws -> Date? {
    let session = try load()
    guard !session.stopped, working(session) == nil, session.queueHead == session.queueTail, session.turn.turn == .idle else { return nil }
    return session.nags.nextTimer(openRequests: try rows.openRequests(id.session), armedWake: try armedWake(), now: client.dueNow())
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

  mutating func interrupt() throws {
    let session = try load()
    guard !session.stopped else { return }
    try rows.markInterrupted(id.session)
    stop(working(session))
  }

  mutating func resume() throws {
    let session = try load()
    guard session.record.hold == .interrupted || session.record.work == .errored else { return }
    try rows.markResumed(id.session)
    try rows.show(id.session, owed: session.turn.owed)
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
    if scriptAt(session.slot.call.key) != nil { try takeToolAnswer(session, .interrupted) }
    for run in scriptRuns() { ctx.send(.cancel, to: run) }
    for stream in try rows.streams(id.session) {
      unstream(stream)
      try forget(stream)
    }
    try rows.archive(id.session, grace: grace)
    invalidateInference()
  }

  mutating func unarchive() throws {
    try rows.unarchive(id.session)
    invalidateInference()
    try advance()
  }

  /// Start over. An unstopped session that started work after main checked keeps it; a stopped session can leave a completed slot whose answer was lost. Queued input waits for the new generation.
  mutating func restart(_ executor: SessionExecutor?, _ route: SessionModelRoute?, _ note: String?, _ runningWork: [String]) throws {
    if let session = try? load(), !session.stopped, working(session) != nil { return }
    let armed = keepsArmed ? try armedSlots() : nil
    let restart = try client.dependencies.yield {
      try rows.restart(id.session, executor: executor, note: note, modelRoute: route, runningWork: runningWork, armed: armed, uuid: client.uuid)
    }
    try write(SessionTurn(generation: restart.generation, position: 1, turn: .inert, reestablish: [], replied: false, nags: turn()?.nags, seen: true, armed: true))
    try db.execute(Seen.delete())
    if armed == nil { try fillArmed() }
    invalidateInference()
    try advance()
  }

  mutating func observed(_ watched: ObservationSlot, _ snapshot: Rows, _ marker: String) throws {
    guard let current = try observation(watched) else { return }
    let observed: Observed
    if case .children = current.slot.kind {
      let errored = snapshot.rows.map { row -> String in
        guard case let .text(id) = row[0] else { preconditionFailure("children ids are text") }
        return id
      }
      let marker = errored.joined(separator: ",")
      if Set(errored).isSubset(of: (current.marker ?? "").split(separator: ",").map(String.init)) {
        if marker == current.marker ?? "" { return }
        observed = .quiet(marker: marker)
      } else {
        observed = .change(text: "Your children errored:\n" + renderedRows(snapshot), marker: marker)
      }
    } else {
      guard case let .observe(sql, _) = current.slot.kind else { preconditionFailure("a plain SQL slot observes a query or children") }
      observed = .change(text: "observed change for \(sql):\n" + renderedRows(snapshot), marker: marker)
    }
    try take(watched, observed)
  }

  mutating func failed(_ watched: ObservationSlot, _ reason: String) throws {
    guard try observation(watched) != nil else { return }
    try take(watched, .failed(text: "observation \(watched.subscription.rawValue) failed and was cancelled: \(reason)"))
  }

  private mutating func observation(_ watched: ObservationSlot) throws -> ArmedSubscription? {
    guard let current = try rows.observation(id.session, watched.subscription), current.observationSlot == watched else {
      ctx.send(.unwatch(watched), to: ObservationMail.recipient)
      return nil
    }
    return current
  }

  private mutating func take(_ watched: ObservationSlot, _ observed: Observed) throws {
    switch try rows.observed(id.session, watched.subscription, token: watched.incarnation, observed) {
    case .ignored: return
    case .ended:
      ctx.send(.unwatch(watched), to: ObservationMail.recipient)
      try forget(watched.subscription)
    case .stands: break
    }
    try look()
  }

  /// A handler slot of the session's ended without its `cancel`: its observer retired it.
  mutating func ended(_ subscription: SubscriptionID) throws {
    try forget(subscription)
  }

  /// An archived session ends the stream instead of taking the event.
  mutating func streamed(_ batch: StreamBatch) throws {
    guard try load().record.lifecycle == .live else {
      if batch.ending == nil { ctx.send(.stop, to: batch.job) }
      return
    }
    try rows.observed(id.session, stream: batch.subscription, url: batch.url, text: batch.text, throttle: batch.throttle, ends: batch.ending != nil, uuid: client.uuid)
    if batch.ending == nil { ctx.send(.acked, to: batch.job) } else { try forget(batch.subscription) }
    try look()
  }

  mutating func attached(_ socket: SocketHandle<TranscriptTail>) throws {
    try catchUp(socket)
  }

  mutating func stepped(_ step: InferenceJob.ID, _ result: StepResult) throws {
    let session = try load()
    if try convertLegacy(session, answering: true) { return }
    if !session.turn.replied { try sendPrompt() }
    guard session.record.lifecycle == .live, step == session.slot.step else { return }
    switch result.ending {
    case let .reply(entry, fullness, warming):
      let unfitReply = try fullness >= client.config.thresholds.hard && !rows.droppable(id.session)
      var appended: [TranscriptItem] = [.assistant(entry)]
      let now = client.now()
      if entry.toolCalls.isEmpty, let nag = session.nags.nag(task: session.isTask, openRequests: try rows.openRequests(id.session), armedWake: try armedWake(), now: client.dueNow()) {
        appended.append(.notification(nag.notification(id: client.uuid(), at: now)))
      }
      try append(session, appended) {
        $0.reply(entry.toolCalls)
        $0.binding = entry.replayBinding
        $0.warmed(warming, at: now)
        $0.input(appended.count - 1)
      }
      if unfitReply {
        try rows.markErrored(id.session, message: unfit(fullness))
        return
      }
      if fullness >= client.config.thresholds.hard, entry.toolCalls.isEmpty {
        start(try load().slot.compaction, .pointer)
        return
      }
    case .cancelled:
      break
    case let .full(fullness):
      if fullness >= client.config.thresholds.hard {
        guard try rows.droppable(id.session) else {
          try rows.markErrored(id.session, message: unfit(fullness))
          return
        }
        start(session.slot.compaction, .pointer)
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
    case .contextTooLong:
      guard try rows.droppable(id.session) else {
        try rows.markErrored(id.session, message: String(describing: InferenceError.contextTooLong))
        return
      }
      start(session.slot.compaction, .pointer)
      return
    case let .requestTooLarge(limit, failure):
      guard try rows.droppable(id.session) else {
        try rows.markErrored(id.session, message: limit.map { String(describing: InferenceError.requestTooLargeAfterCompaction(limitBytes: $0)) } ?? failure)
        return
      }
      start(session.slot.compaction, .pointer)
      return
    case let .handoff(binding):
      start(session.slot.compaction, .handoff(binding))
      return
    case let .roster(notice):
      try append(session, [.notification(.init(
        id: client.uuid(), timestamp: client.now(), kind: .context, subscriptionID: ToolRosterChanged.source, content: .init(text: notice),
      ))]) { $0.input(1) }
    case let .parked(failure):
      try rows.markErrored(id.session, message: failure)
      return
    case .pingFailed:
      var turn = session.turn
      turn.warming = nil
      turn.pingUnanswered()
      try write(turn)
      try advance()
      return
    }
    try advance()
  }

  mutating func called(_ call: ToolCallJob.ID, _ answer: ToolCallAnswer) throws {
    let session = try load()
    if try convertLegacy(session, answering: true) { return }
    guard session.record.lifecycle == .live, call == session.slot.call else { return }
    try takeToolAnswer(session, answer)
    try advance()
  }

  mutating func scriptAnswered(_ call: ToolCallJob.ID, _ answer: ToolCallAnswer) throws {
    try called(call, answer)
  }

  private mutating func takeToolAnswer(_ session: SessionState, _ answer: ToolCallAnswer) throws {
    let provenance: ToolResultItem.Provenance = session.turn.call.map { .toolCall(ToolCallID($0.id)) } ?? .compactionReestablishment
    switch answer {
    case let .result(payload, context): try writeToolResult(session, provenance, payload, context: context)
    case .interrupted: try writeToolResult(session, provenance, .failure(.init(message: interruptedToolMessage)))
    case .serverRestarted: try writeToolResult(session, provenance, .failure(.init(message: serverRestartedToolMessage)))
    }
  }

  mutating func scriptPosted(_ handle: String, _ text: String) throws {
    guard try rows.hydrate(id.session).record.lifecycle == .live else { return }
    let notice = SystemNotification(id: client.uuid(), timestamp: client.now(), kind: .script, subscriptionID: .script(String(handle.dropFirst("script.".count))), content: .init(text: text))
    try put(SessionPut(.notification(notice)))
  }

  mutating func scriptEnded(_ run: ScriptJob.ID) throws {
    let handle = String(run.key.dropFirst(id.key.count + 1))
    try db.execute(SessionScript.where { $0.handle.eq(handle) }.delete())
  }

  mutating func compacted(_ compaction: CompactionJob.ID, _ answer: CompactionAnswer) throws {
    let session = try load()
    if session.legacy {
      guard session.turn.turn == .converting, compaction == session.slot.compaction else {
        _ = try convertLegacy(session, answering: true)
        return
      }
    }
    guard session.record.lifecycle == .live, compaction == session.slot.compaction else { return }
    switch answer {
    case .folded(var head, let kept, let transition, let call):
      head.snapshot.subscriptions = try armedSlots()
      let closing = call.flatMap { call in
        session.turn.turn == .folding(call: call) ? nil : ToolResultItem(id: client.uuid(), timestamp: client.now(), provenance: .toolCall(call), payload: .compact(.init(summary: head.summary)))
      }
      let after = transition?.notice.map { noticeLines($0, source: ModelRouteTransition.source) } ?? []
      try roll(session, head: head, kept: kept, portable: transition?.binding != nil, closing: closing.map { TranscriptItem.toolResult($0).lines(session: id.session) } ?? [], after: after, transition: transition)
    case let .refused(call, message):
      try writeToolResult(session, .toolCall(call), .failure(.init(message: message)))
    case let .handoff(head, kept, binding, after):
      var head = head
      head.snapshot.subscriptions = try armedSlots()
      try roll(session, head: head, kept: kept, portable: true, after: after, binding: binding)
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
      if turn() == nil { try write(session.turn) }
      if !keepsArmed {
        try fillArmed()
        var turn = try load().turn
        turn.armed = true
        try write(turn)
      }
      if try convertLegacy(session) { return }
      guard !session.stopped, working(session) == nil, try next(session) else { return }
    }
  }

  private mutating func convertLegacy(_ session: SessionState, answering: Bool = false) throws -> Bool {
    guard session.legacy else { return false }
    if !session.stopped, try answering || session.queueHead > session.queueTail || session.turn.owed != .noRun || session.turn.turn.isFolding || session.turn.turn == .converting || working(session) != nil || session.nags.nag(task: session.isTask, openRequests: rows.openRequests(id.session), armedWake: armedWake(), now: client.dueNow()) != nil {
      if turn() == nil { try write(session.turn) }
      var turn = self.turn()!
      if turn.turn != .converting {
        turn.position += 1
        turn.turn = .converting
        try write(turn)
      }
      start(try load().slot.compaction, .legacy)
    }
    return true
  }

  /// The session's next step; true when it was written and there may be another.
  private mutating func next(_ session: SessionState) throws -> Bool {
    let turn = session.turn
    // A pending fold has no work or nags: only a delivery runs the fold.
    if case let .folding(call) = turn.turn {
      if session.queueHead > session.queueTail { start(session.slot.compaction, .fold(call)) }
      return false
    }
    if let call = turn.call { return try run(call, session) }
    if session.queueHead > session.queueTail {
      let drained = try rows.drainQueue(id.session)
      try move(wrote: drained.items) { $0.input(drained.items.count) }
      return true
    }
    if turn.turn == .model {
      if let call = turn.reestablish.first {
        try start(session.slot.call, call)
      } else {
        start(session.slot.step, ping: turn.origin == true)
      }
      return false
    }
    // Only a model that stopped is asked whether it may; a generation that never
    // ran (created, restarted) is inert. What is left is a park wake (`nextWake`).
    guard turn.turn == .idle else { return false }
    let openRequests = try rows.openRequests(id.session)
    let now = client.now()
    if let nag = session.nags.nag(task: session.isTask, openRequests: openRequests, armedWake: try armedWake(), now: client.dueNow()) {
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
        if let name = arguments.bookmark {
          guard let bookmark = session.turn.bookmarks?[name], bookmark < (try rows.lastReplyPosition(id.session))! else { throw BookmarkNotFound(name: name) }
        }
      } catch let notFound as BookmarkNotFound {
        try writeToolResult(session, .toolCall(callID), .failure(.init(message: "bookmark \"\(notFound.name)\" not found before this reply; name an earlier bookmark or omit it to fold everything")))
        return true
      } catch {
        try writeToolResult(session, .toolCall(callID), .failure(.init(message: "invalid compact arguments: \(error)")))
        return true
      }
      guard arguments.park else {
        start(session.slot.compaction, .fold(callID))
        return false
      }
      if let refusal = ParkRefusal(session.nags, task: session.isTask, openRequests: try rows.openRequests(id.session)) {
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

  private func load() throws -> SessionState {
    let hydration = try rows.hydrate(id.session)
    let turn = try turn() ?? SessionTurn(generation: hydration.generation, position: rows.transcriptLineCount(id.session))
    return SessionState(hydration, turn: turn)
  }

  /// What the generation was shown, as the tool call at its end goes by it.
  func shown() throws -> ToolExecutionState {
    try Seen.state(db.rows(Seen.all))
  }

  /// The row as the cell last wrote it: nil for a session whose cell has taken no step.
  func turn() -> SessionTurn? {
    guard var turn = db.rows(SessionTurn.all).first else { return nil }
    turn.nags = turn.nags ?? NagState()
    return turn
  }

  /// The job the session works on: one at its transcript's end that has not ended, or has ended with something still to write. A step that was cancelled or parked has nothing.
  private func working(_ session: SessionState) -> Slot.Work? {
    if let script = scriptAt(session.slot.call.key) { return .script(script) }
    return session.slot.working(exists: { work in
      switch work {
      case let .step(id): ctx.exists(id)
      case let .call(id): ctx.exists(id)
      case .script: preconditionFailure("script membership is resolved before the slot")
      case let .compaction(id): ctx.exists(id)
      }
    }, outcome: { ctx.job($0).outcome() })
  }

  /// Tells the work at hand when to give the turn back to the input that waits. A compaction never yields.
  private mutating func yield(_ work: Slot.Work) throws {
    guard let by = try rows.yieldDeadline(id.session) else { return }
    switch work {
    case let .step(step): ctx.send(.yield(by: by), to: step)
    case let .call(call): ctx.send(.yield(by: by), to: call)
    case let .script(script): ctx.send(.yield(by: by), to: script)
    case .compaction: break
    }
  }

  private mutating func stop(_ work: Slot.Work?) {
    switch work {
    case let .step(step)?: ctx.send(.interrupt, to: step)
    case let .call(call)?: ctx.send(.interrupt, to: call)
    case let .script(script)?: ctx.send(.interrupt, to: script)
    case .compaction?, nil: break
    }
  }

  private mutating func start(_ step: InferenceJob.ID, ping: Bool = false) {
    let slot = Slot(step)
    ctx.create(step, params: .init(session: id.session, generation: slot.generation, position: slot.position, ping: ping))
  }

  private mutating func start(_ call: ToolCallJob.ID, _ toolCall: ToolCall) throws {
    if toolCall.name == "run_script" {
      let plan: ScriptPlan
      do { plan = try ScriptPlan(toolCall) }
      catch {
        let problem = error as? ToolProblem
        try takeToolAnswer(try load(), .result(.failure(.init(message: problem?.message ?? String(describing: error), code: problem?.code)), context: nil))
        ctx.send(id).look()
        return
      }
      return try startScript(call, toolCall, plan)
    }
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
    var turn = session.turn
    let pending = turn.call != nil
    change(&turn)
    var lines: [TranscriptLine] = []
    let first = try rows.lineEnd(id.session).position + 1
    for item in items {
      turn.nags!.apply(item)
      if let origin = item.cacheWarmingOrigin { turn.origin = origin }
      let rendered = item.lines(session: id.session)
      if case let .bookmark(marker) = item {
        turn.bookmarks = turn.bookmarks ?? [:]
        turn.bookmarks?[marker.name ?? ""] = first + lines.count
        turn.bookmarks?[""] = first + lines.count
      }
      try see([item], position: first + lines.count)
      if rendered.first?.key == LineKey.scope, pending {
        turn.held = (turn.held ?? []) + rendered
      } else {
        lines += rendered
      }
    }
    if pending, turn.call == nil {
      lines += turn.held ?? []
      turn.held = nil
    }
    try rows.append(id.session, lines: lines)
    try write(turn)
  }

  private mutating func move(wrote items: [TranscriptItem] = [], _ change: (inout SessionTurn) -> Void) throws {
    let session = try load()
    var turn = session.turn
    change(&turn)
    for item in items {
      turn.nags!.apply(item)
      if let origin = item.cacheWarmingOrigin { turn.origin = origin }
      if case let .notification(notice) = item, notice.endsSubscription { try forget(notice.subscriptionID) }
    }
    try see(items, position: try rows.lineEnd(id.session).position)
    try write(turn)
  }

  private mutating func see(_ items: some Sequence<TranscriptItem>, position: Int) throws {
    for item in items {
      for var seen in try Seen.of(item) {
        if seen.kind == .text, !db.rows(seen.earlier).isEmpty { continue }
        seen.position = position
        try db.execute(seen.earlier.delete())
        try db.execute(Seen.insert { seen })
      }
    }
  }

  private mutating func roll(_ session: SessionState, head: GenerationHead, kept: Range<Int>?, portable: Bool = false, closing: [TranscriptLine] = [], after: [TranscriptLine] = [], transition: ModelRouteTransition? = nil, binding: ReplayBinding? = nil) throws {
    let generation = try rows.writeGeneration(id.session, closing: closing + (session.turn.held ?? []), head: head, kept: kept, portable: portable, after: after, transition: transition)
    var turn = SessionTurn(generation: generation, position: try rows.transcriptLineCount(id.session), turn: .model, reestablish: head.reestablishmentCalls, replied: false, nags: session.turn.nags, seen: true, armed: true)
    turn.binding = binding ?? transition?.binding ?? session.turn.binding
    turn.warming = session.turn.warming
    turn.origin = session.turn.origin
    try write(turn)
    let retained = db.rows(Seen.all).filter { $0.kind == .file && kept?.contains($0.position ?? -1) == true }
    try db.execute(Seen.delete())
    for var seen in retained {
      seen.position = 0
      try db.execute(Seen.insert { seen })
    }
    invalidateInference()
  }

  private func noticeLines(_ text: String, source: SubscriptionID) -> [TranscriptLine] {
    TranscriptItem.notification(.init(id: client.uuid(), timestamp: client.now(), kind: .context, subscriptionID: source, content: .init(text: text))).lines(session: id.session)
  }

  private mutating func write(_ turn: SessionTurn) throws {
    try db.execute(SessionTurn.delete())
    try db.execute(SessionTurn.insert { turn })
    try rows.show(id.session, owed: turn.owed)
  }

  private mutating func invalidateInference() {
    let (session, invalidate) = (id.session, client.config.invalidateInference)
    ctx.emit { await invalidate(session) }
  }

  var rows: SessionRows {
    SessionRows(host: db.host, store: client.store)
  }

  var client: LoopClient {
    ctx.dependency(LoopClient.self)
  }
}

/// A session as one message of its cell finds it.
struct SessionState {
  let record: SessionRecord
  let generation: Int
  let legacy: Bool
  let queueHead: Int
  let queueTail: Int
  let turn: SessionTurn
  let nags: NagState
  let slot: Slot

  init(_ hydration: SessionHydration, turn: SessionTurn) {
    record = hydration.record
    generation = hydration.generation
    legacy = hydration.legacy
    queueHead = hydration.queueHead
    queueTail = hydration.queueTail
    self.turn = turn
    nags = turn.nags!
    slot = Slot(session: hydration.record.id, generation: hydration.generation, position: turn.position, stepTry: hydration.stepTry)
  }

  var isTask: Bool { record.kind == .task }
  var stopped: Bool { record.stopped }

  /// Nothing to do, now or once its job answers: what an archive or a restart waits for.
  var settled: Bool { stopped || (queueHead == queueTail && turn.turn != .model && turn.call == nil) }
}

/// The cell's write counter names every job that can answer there: `<session>:<generation>:<position>` for a tool call and a compaction, plus `:<resumes>` for a step.
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

  var step: InferenceJob.ID { .init("\(key):\(stepTry)") }
  var call: ToolCallJob.ID { .init(key) }
  var compaction: CompactionJob.ID { .init(key) }

  enum Work {
    case step(InferenceJob.ID), call(ToolCallJob.ID), compaction(CompactionJob.ID), script(ScriptJob.ID)
  }

  func working(exists: (Work) -> Bool, outcome: (InferenceJob.ID) -> StepResult?) -> Work? {
    if exists(.compaction(compaction)) { return .compaction(compaction) }
    if exists(.step(step)) {
      switch outcome(step)?.ending {
      case .cancelled?, .parked?: return nil
      default: return .step(step)
      }
    }
    return exists(.call(call)) ? .call(call) : nil
  }
}

/// How the session tables write their times.
let queueDate = Date.ISO8601FormatStyle(includingFractionalSeconds: true)

private func unfit(_ fullness: Double) -> String {
  "the context is \(Int((fullness * 100).rounded()))% full with nothing left to drop: the prompt and the generation's head do not fit this model"
}

let interruptedToolMessage = """
Tool execution was interrupted by the user. It may have partially run; \
it will not be retried automatically.
"""

let serverRestartedToolMessage = """
The server restarted before this tool call finished. Retry it; a script or an exec may have partially run.
"""

extension SessionRecord {
  /// Nothing runs it: held, errored, archived, or left from an executor this build no longer has.
  var stopped: Bool { hold == .interrupted || work == .errored || lifecycle != .live || executor.isRetired }
}

extension Address where Target == SessionCell {
  var session: SessionID { SessionID(key) }
}

extension SessionTurn.Turn {
  var isFolding: Bool {
    if case .folding = self { true } else { false }
  }
}
