#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import SessionDomain
import func SpaceCore.isUnreadableSessionData
import struct SpaceCore.SessionDataRow
import struct SpaceCore.SessionPut
import struct SpaceCore.SessionQueueRow
import enum SpaceCore.SessionRunState
import struct SpaceCore.SessionRuntimeRow
import enum SpaceCore.Sessions
import typealias SpaceCore.SessionWork
import enum SpaceCore.SQLiteDateFormat
import StructuredQueries
import Wuwei
import WuweiQueries

extension SessionCell {
  mutating func openGeneration(_ key: String, generation: Int64) throws {
    try db.execute(SessionRuntimeRow.where { $0.sessionID.eq(key) }.update { $0.generation = generation })
  }

  private func throttledDue(_ key: String, topic: String, throttle: Double, now: Date) throws -> Date {
    let tail = try Sessions.runtime(key, in: db).queueTail
    guard let last = db.rows(SessionQueueRow.where { $0.sessionID.eq(key) && $0.topic.eq(Optional(topic)) }.order { $0.id.desc() }.limit(1)).first else { return now }
    let due = try SQLiteDateFormat.date(from: last.dueAt ?? last.enqueuedAt)
    guard last.id <= tail else { return due }
    return max(now, max(due, try SQLiteDateFormat.date(from: last.enqueuedAt)).addingTimeInterval(throttle))
  }

  mutating func removeInput(_ key: String, topic: String) throws {
    let tail = try Sessions.runtime(key, in: db).queueTail
    try db.execute(SessionQueueRow.where { $0.sessionID.eq(key) && $0.topic.eq(Optional(topic)) && $0.id.gt(tail) }.delete())
  }

  mutating func insertInput(_ key: String, _ put: SessionPut, nowDate: Date) throws {
    let record = try Sessions.record(key, in: db)
    let inputID = put.input.id.uuidString.lowercased()
    guard db.rows(SessionQueueRow.where { $0.sessionID.eq(key) && $0.inputID.eq(inputID) }).isEmpty else { return }
    let now = SQLiteDateFormat.string(from: nowDate)
    var due = put.due
    if let topic = put.topic {
      if let throttle = put.throttle { due = try throttledDue(key, topic: topic, throttle: throttle, now: nowDate) }
      try removeInput(key, topic: topic)
    }
    let next = (db.rows(SessionQueueRow.where { $0.sessionID.eq(key) }.select { $0.id.max() }).first! ?? 0) + 1
    let later = due.flatMap { $0 > nowDate ? SQLiteDateFormat.string(from: $0) : nil }
    let row = SessionQueueRow(sessionID: key, id: next, inputID: inputID, payload: try Sessions.encode(put.input.capped()), enqueuedAt: now, topic: put.topic, dueAt: later)
    try db.execute(SessionQueueRow.insert { row })
    if record.work == .noWork, later == nil { try markHasWork(key, now: now) }
  }

  mutating func deferNotDue(_ key: String, tail: Int64, at clock: String) throws {
    let later = db.rows(SessionQueueRow.where { $0.sessionID.eq(key) && $0.id.gt(tail) && $0.dueAt.gt(Optional(clock)) }.order { $0.id }.select { $0.id })
    guard !later.isEmpty else { return }
    var next = db.rows(SessionQueueRow.where { $0.sessionID.eq(key) }.select { $0.id.max() }).first!!
    for id in later {
      next += 1
      try db.execute("UPDATE session_queue SET id = ? WHERE session_id = ? AND id = ?", .integer(next), .text(key), .integer(id))
    }
  }

  mutating func recoverRestartQueue(_ key: String, tail: Int64) throws -> (tail: Int64, dropped: Int) {
    let rows = db.rows(SessionQueueRow.where { $0.sessionID.eq(key) && $0.id.gt(tail) }.order { $0.id })
    var readable: [Int64] = []
    var dropped = 0
    for row in rows {
      do {
        _ = try Sessions.decode(QueueInput.self, from: row.payload)
        _ = try SQLiteDateFormat.date(from: row.enqueuedAt)
        readable.append(row.id)
      } catch where isUnreadableSessionData(error) {
        dropped += 1
      }
    }
    guard dropped > 0 else { return (tail, 0) }
    let head = db.rows(SessionQueueRow.where { $0.sessionID.eq(key) }.select { $0.id.max() }).first!!
    for (offset, id) in readable.enumerated() {
      try db.execute("UPDATE session_queue SET id = ? WHERE session_id = ? AND id = ?", .integer(head + Int64(offset) + 1), .text(key), .integer(id))
    }
    try db.execute(SessionRuntimeRow.where { $0.sessionID.eq(key) }.update { $0.queueTail = head })
    return (head, dropped)
  }

  mutating func markHasWork(_ key: String, now: String) throws {
    try db.execute(SessionDataRow.where { $0.id.eq(key) && $0.work.eq("no_work") }.update { $0.work = "has_work"; $0.lastActivityAt = now })
  }

  mutating func refreshWork(_ key: String, owed: SessionRunState, now: String) throws {
    let record = try Sessions.record(key, in: db)
    guard record.work != .errored else { return }
    let runtime = try Sessions.runtime(key, in: db)
    let backlog = db.rows(SessionQueueRow.where { $0.sessionID.eq(key) && $0.id.gt(runtime.queueTail) && ($0.dueAt.is(nil) || $0.dueAt.lte(Optional(now))) }.asSelect().count()).first!
    let derived: SessionWork = (backlog > 0 || owed != .noRun) ? .hasWork : .noWork
    let run: SessionRunState = if record.hold != .normal || record.lifecycle != .live {
      .noRun
    } else if owed == .noRun, derived == .hasWork {
      .inference
    } else {
      owed
    }
    if derived != record.work {
      try db.execute(SessionDataRow.where { $0.id.eq(key) }.update { $0.work = derived.rawValue; $0.lastActivityAt = now })
    }
    try setRunState(key, run, now: now)
  }

  mutating func setRunState(_ key: String, _ run: SessionRunState, now: String) throws {
    let progress = run == .noRun ? nil : now
    try db.execute(SessionDataRow.where { $0.id.eq(key) && $0.runState.neq(run.rawValue) }.update {
      $0.runState = run.rawValue
      $0.runProgressAt = #bind(progress)
      $0.lastActivityAt = now
    })
  }

  mutating func putNextTimers(_ key: String, after drained: [QueueInput], now: Date) throws {
    for case let .notification(notice) in drained where notice.kind == .timer {
      guard let schedule = notice.schedule, let next = schedule.next(after: max(now, notice.timestamp)) else { continue }
      try insertInput(key, Sessions.timerPut(key, id: notice.subscriptionID, schedule: schedule, message: notice.content.text, due: next), nowDate: now)
    }
  }
}
