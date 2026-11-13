#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import SessionDomain
import struct SpaceCore.QueueDrain
import struct SpaceCore.SessionDataRow
import struct SpaceCore.SessionHydration
import struct SpaceCore.SessionLineRow
import enum SpaceCore.SessionModelRoutes
import enum SpaceCore.SessionPrompts
import struct SpaceCore.SessionQueueRow
import enum SpaceCore.SessionRunState
import struct SpaceCore.SessionRuntimeRow
import enum SpaceCore.Sessions
import struct SpaceCore.SessionStore
import enum SpaceCore.SessionStoreError
import struct SpaceCore.SpaceCell
import enum SpaceCore.SQLiteDateFormat
import struct SpaceCore.StoredTranscriptLine
import StructuredQueries
import Wuwei
import WuweiQueries

extension SessionCell {
  var rowNow: String { SQLiteDateFormat.string(from: now()) }

  func hydrate(_ id: SessionID) throws -> SessionHydration {
    try Sessions.hydrate(id.rawValue, at: rowNow, in: db)
  }

  func openRequests(_ id: SessionID) throws -> [OpenRequest] {
    try SpaceCell.openRequests(id.rawValue, in: db)
  }

  func yieldDeadline(_ id: SessionID) throws -> Date? {
    try Sessions.yieldDeadline(id.rawValue, at: rowNow, in: db)
  }

  func nextDue(_ id: SessionID) throws -> Date? {
    try db.rows(SessionQueueRow.where { $0.sessionID.eq(id.rawValue) && $0.id.gt(SessionRuntimeRow.where { $0.sessionID.eq(id.rawValue) }.select { $0.queueTail }) && $0.dueAt.gt(Optional(rowNow)) }.select { $0.dueAt.min() }).first!.map(SQLiteDateFormat.date(from:))
  }

  mutating func show(_ id: SessionID, owed: SessionRunState) throws {
    try refreshWork(id.rawValue, owed: owed, now: rowNow)
  }

  mutating func drainQueue(_ id: SessionID) throws -> QueueDrain {
    let key = id.rawValue
    let now = rowNow
    let runtime = try Sessions.runtime(key, in: db)
    let clock = now
    try deferNotDue(key, tail: runtime.queueTail, at: clock)
    let entries = try Sessions.undrained(key, tail: runtime.queueTail, at: clock, in: db)
    guard let lastID = entries.last?.id else {
      return QueueDrain(items: [], queueTail: Int(runtime.queueTail))
    }
    let generationStart = try Sessions.generationStart(key, generation: runtime.generation, in: db)
    var quoted: Set<ConversationID> = []
    let items = try entries.map { entry -> TranscriptItem in
      guard case var .message(message) = entry.input else { return entry.input.transcriptItem }
      message.sender = try Sessions.attributed(message.sender, in: db)
      if let generationStart, quoted.insert(message.conversationID).inserted {
        let exchange = try Sessions.staleExchange(
          message.conversationID, session: key, generation: runtime.generation, startedAt: generationStart, in: db,
        )
        message.content = message.content.following(try exchange.map { earlier in
          EarlierMessage(id: earlier.id, sender: try Sessions.attributed(earlier.sender, in: db), timestamp: earlier.createdAt, text: earlier.content.text)
        })
      }
      return .message(message)
    }
    try Sessions.appendLines(key, generation: runtime.generation, items.flatMap { $0.lines(session: id) }, in: &db)
    try db.execute(SessionRuntimeRow.where { $0.sessionID.eq(key) }.update { $0.queueTail = Int64(lastID) })
    try putNextTimers(key, after: entries.map(\.input), now: try SQLiteDateFormat.date(from: now))
    return QueueDrain(items: items, queueTail: lastID, firings: try Sessions.firings(of: entries.map(\.input), in: db))
  }

  @discardableResult
  mutating func append(_ id: SessionID, lines: [TranscriptLine]) throws -> Int {
    let key = id.rawValue
    return Int(try Sessions.appendLines(key, generation: try Sessions.runtime(key, in: db).generation, lines, in: &db))
  }

  func droppable(_ id: SessionID) throws -> Bool {
    let key = id.rawValue
    let generation = try Sessions.runtime(key, in: db).generation
    return !db.rows(SessionLineRow.where {
      $0.sessionID.eq(key) && $0.generation.eq(generation)
        && !$0.key.in(["system", "group", "session", LineKey.pressure])
        && #sql("\($0.key) NOT GLOB \(bind: LineKey.head + "*")", as: Bool.self)
    }.limit(1)).isEmpty
  }

  func transcriptLineCount(_ id: SessionID) throws -> Int {
    let key = id.rawValue
    return try Sessions.transcriptLineCount(key, generation: Sessions.runtime(key, in: db).generation, in: db)
  }

  func lastReplyPosition(_ id: SessionID) throws -> Int? {
    let key = id.rawValue
    let generation = try Sessions.runtime(key, in: db).generation
    return db.rows(SessionLineRow.where { $0.sessionID.eq(key) && $0.generation.eq(generation) && $0.role.eq(TranscriptLine.Role.assistant.rawValue) }
      .order { $0.position.desc() }.limit(1).select(\.position)).first.map(Int.init)
  }

  func lastLineRole(_ id: SessionID) throws -> TranscriptLine.Role? {
    let key = id.rawValue
    let generation = try Sessions.runtime(key, in: db).generation
    return db.rows(SessionLineRow.where { $0.sessionID.eq(key) && $0.generation.eq(generation) }
      .order { $0.position.desc() }.limit(1).select(\.role)).first.flatMap(TranscriptLine.Role.init(rawValue:))
  }

  func transcriptLines(_ id: SessionID) throws -> [StoredTranscriptLine] {
    let key = id.rawValue
    return try Sessions.transcriptLines(key, generation: try Sessions.runtime(key, in: db).generation, in: db)
  }

  @discardableResult
  mutating func writeGeneration(
    _ id: SessionID,
    closing: [TranscriptLine] = [],
    head: GenerationHead,
    kept: Range<Int>? = nil,
    portable: Bool = false,
    after: [TranscriptLine] = [],
    transition: ModelRouteTransition? = nil,
  ) throws -> Int {
    let key = id.rawValue
    let generation = try Sessions.runtime(key, in: db).generation
    try Sessions.appendLines(key, generation: generation, closing, in: &db)
    var lines = head.lines(session: id)
    if let kept {
      let portable = portable || transition?.binding != nil
      lines += try Sessions.transcriptLines(key, generation: generation, in: db)
        .filter { kept.contains($0.position) && $0.key != LineKey.pressure }
        .compactMap { try $0.line().carried(portable: portable) }
    }
    if let transition { try SessionModelRoutes.commitTransition(key, transition: transition, in: &db) }
    try openGeneration(key, generation: generation + 1)
    try Sessions.appendLines(key, generation: generation + 1, lines + after, in: &db)
    try SessionPrompts.invalidate(key, in: &db)
    return Int(generation) + 1
  }

  mutating func markInterrupted(_ id: SessionID) throws {
    let key = id.rawValue
    let now = rowNow
    _ = try Sessions.record(key, in: db)
    try db.execute(SessionDataRow.where { $0.id.eq(key) }.update { $0.hold = "interrupted"; $0.lastActivityAt = now })
    try setRunState(key, .noRun, now: rowNow)
  }

  mutating func markResumed(_ id: SessionID) throws {
    let key = id.rawValue
    let now = rowNow
    let record = try Sessions.record(key, in: db)
    try record.executor.requireSupported()
    try db.execute(SessionDataRow.where { $0.id.eq(key) }.update { $0.hold = "normal"; $0.errorMessage = #bind(Optional<String>.none); $0.lastActivityAt = now })
    let stepTry = try Sessions.runtime(key, in: db).stepTry + 1
    try db.execute(SessionRuntimeRow.where { $0.sessionID.eq(key) }.update { $0.stepTry = #bind(stepTry) })
    if record.work == .errored {
      try db.execute(SessionDataRow.where { $0.id.eq(key) }.update { $0.work = "no_work" })
    }
  }

  mutating func retitle(_ id: SessionID, _ title: String) throws {
    let key = id.rawValue
    _ = try Sessions.record(key, in: db)
    let now = rowNow
    try db.execute(SessionDataRow.where { $0.id.eq(key) }.update { $0.title = title; $0.lastActivityAt = now })
  }

  mutating func retag(_ id: SessionID, _ tags: [String]) throws {
    let key = id.rawValue
    _ = try Sessions.record(key, in: db)
    let payload = try Sessions.encode(tags)
    try db.execute(SessionDataRow.where { $0.id.eq(key) }.update { $0.tags = payload })
  }

  @discardableResult
  mutating func archive(_ id: SessionID, grace: Duration) throws -> Date {
    let nowDate = now()
    let deadline = nowDate.addingTimeInterval(Double(grace.components.seconds) + Double(grace.components.attoseconds) / 1e18)
    let key = id.rawValue
    let expires = SQLiteDateFormat.string(from: deadline)
    let now = SQLiteDateFormat.string(from: nowDate)
    try db.execute(SessionDataRow.where { $0.id.eq(key) }.update {
      $0.lifecycle = "archived"
      $0.graceExpiresAt = #bind(expires)
      $0.lastActivityAt = now
      $0.runState = "no_run"
      $0.runProgressAt = #bind(Optional<String>.none)
    })
    if let parent = try Sessions.record(key, in: db).parent { ctx.send(SessionCell.ID(parent.rawValue)).reconcileChildren() }
    return deadline
  }

  mutating func unarchive(_ id: SessionID) throws {
    let key = id.rawValue
    let nowDate = now()
    let record = try Sessions.record(key, in: db)
    guard case let .archived(graceExpiresAt) = record.lifecycle else { return }
    try record.executor.requireSupported()
    guard nowDate < graceExpiresAt else { throw SessionStoreError.archiveGraceExpired(key) }
    let now = SQLiteDateFormat.string(from: nowDate)
    try db.execute(SessionDataRow.where { $0.id.eq(key) }.update {
      $0.lifecycle = "live"
      $0.graceExpiresAt = #bind(Optional<String>.none)
      $0.lastActivityAt = now
    })
    try reconcileChildren()
    if let parent = record.parent { ctx.send(SessionCell.ID(parent.rawValue)).watchChildren(nowDate) }
  }
}
