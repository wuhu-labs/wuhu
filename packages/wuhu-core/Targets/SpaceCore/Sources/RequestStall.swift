#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import GRDB
import SessionDomain

/// The stall clock of one open request, kept in its parent's subscription
/// slot. Time the task spends in a suppressing wait is credited to `paused`
/// from the wait's real start, so a wait stops the clock without resetting
/// it.
public struct RequestStall: Hashable, Sendable, Codable {
  public static let defaultSeconds: Double = 1800

  public var request: RequestID
  public var task: SessionID
  public var seconds: Double
  var anchor: Date
  var paused: Double
  var waitingSince: Date?
  var alerted: Bool

  init(request: RequestID, task: SessionID, seconds: Double, openedAt: Date) {
    self.request = request
    self.task = task
    self.seconds = seconds
    anchor = openedAt
    paused = 0
    waitingSince = nil
    alerted = false
  }
}

struct StallSight: Hashable, Sendable {
  var progress: Date?
  var waiting: Bool
  /// When the earliest current wait began; nil means it predates the
  /// clock's anchor.
  var since: Date?
  /// When the waits end on their own: the earliest due one-shot timer.
  var until: Date?
  var state: String

  init(progress: Date?, waiting: Bool, since: Date? = nil, until: Date? = nil, state: String) {
    self.progress = progress
    self.waiting = waiting
    self.since = since
    self.until = until
    self.state = state
  }
}

extension RequestStall {
  struct Step: Hashable, Sendable {
    var clock: RequestStall
    var next: Date
    var alerts: Bool
  }

  // Fire times round-trip through millisecond strings, so a check that wakes
  // a hair before its due time still counts as due.
  private static let slack: Double = 0.01

  func step(_ sight: StallSight, now: Date) -> Step {
    var clock = self
    if let progress = sight.progress, progress > anchor {
      clock.anchor = progress
      clock.paused = 0
      clock.alerted = false
      clock.waitingSince = nil
    }
    if sight.waiting {
      let since = max(sight.since ?? clock.anchor, clock.anchor)
      clock.waitingSince = min(clock.waitingSince ?? since, since)
      let next = min(now.addingTimeInterval(min(60, seconds)), sight.until ?? .distantFuture)
      return Step(clock: clock, next: next, alerts: false)
    }
    if let since = clock.waitingSince {
      clock.paused += max(0, now.timeIntervalSince(since))
      clock.waitingSince = nil
    }
    if clock.alerted {
      return Step(clock: clock, next: now.addingTimeInterval(seconds), alerts: false)
    }
    let elapsed = now.timeIntervalSince(clock.anchor) - clock.paused
    guard elapsed + Self.slack >= seconds else {
      return Step(clock: clock, next: now.addingTimeInterval(seconds - elapsed), alerts: false)
    }
    clock.alerted = true
    return Step(clock: clock, next: now.addingTimeInterval(seconds), alerts: true)
  }

  func alertText(_ sight: StallSight) -> String {
    let minutes = Int((seconds / 60).rounded())
    let span = minutes >= 1 ? "\(minutes) min" : "\(Int(seconds)) s"
    return """
    Request \(request.rawValue) on task \(task.rawValue) has shown no progress for \(span); \
    last progress \(SQLiteDateFormat.string(from: anchor)). The task is \(sight.state). \
    Check on it: message it, or archive it if it is lost.
    """
  }
}

extension SessionStore {
  /// One look at a request's stall clock. It retires the slot once the
  /// request has its final or the task is archived, and otherwise advances
  /// the clock, enqueuing the parent's alert when the stall runs out.
  /// `liveScripts` names the sessions with a script running in this process;
  /// worker-hosted scripts are read from their owner rows.
  public func checkRequestStall(
    _ parent: SessionID,
    subscriptionID: SubscriptionID,
    now: Date,
    liveScripts: Set<SessionID> = [],
  ) async throws {
    let key = parent.rawValue
    let alerted = try await writer.write { db -> Bool in
      guard let row = try SubscriptionRow.find(key, subscriptionID.rawValue, in: db) else { return false }
      let armed = try armedSubscription(row)
      guard case let .requestStall(clock) = armed.slot.kind else { return false }
      func retire() throws {
        try db.execute(
          sql: "DELETE FROM session_subscriptions WHERE session_id = ? AND subscription_id = ?",
          arguments: [key, subscriptionID.rawValue],
        )
      }
      guard try Sessions.record(clock.task.rawValue, in: db).lifecycle == .live,
            try !Sessions.requestClosed(clock.request, in: db)
      else {
        try retire()
        return false
      }
      let sight = try Sessions.stallSight(clock, now: now, liveScripts: liveScripts, in: db)
      let step = clock.step(sight, now: now)
      if step.alerts {
        let notification = SystemNotification(
          id: UUID.deterministic("stall", key, clock.request.rawValue, SQLiteDateFormat.string(from: step.clock.anchor)),
          timestamp: now,
          kind: .requestStall,
          subscriptionID: subscriptionID,
          requestID: clock.request,
          content: .init(text: step.clock.alertText(sight)),
        )
        _ = try Sessions.enqueue(key, input: .notification(notification), nowDate: now, in: db)
      }
      var slot = armed.slot
      slot.kind = .requestStall(step.clock)
      var advanced = row
      advanced.payload = try Sessions.encode(slot)
      advanced.nextFireAt = SQLiteDateFormat.string(from: step.next)
      if step.alerts { advanced.lastFiredAt = SQLiteDateFormat.string(from: now) }
      try SubscriptionRow.save(advanced, in: db)
      return step.alerts
    }
    if alerted { signals.post(parent) }
  }
}

extension Sessions {
  static func requestClosed(_ request: RequestID, in db: Database) throws -> Bool {
    try Bool.fetchOne(
      db,
      sql: "SELECT EXISTS (SELECT 1 FROM messages WHERE request_id = ? AND kind = 'final')",
      arguments: [request.rawValue],
    ) ?? false
  }

  // Progress is read over the task and every session under it; waits only on
  // the task itself, since its open request on a child already covers that
  // child's work.
  static func stallSight(_ clock: RequestStall, now: Date, liveScripts: Set<SessionID> = [], in db: Database) throws -> StallSight {
    let task = clock.task.rawValue
    let tree = """
    WITH RECURSIVE tree(id) AS (
      SELECT ? UNION SELECT s.id FROM sessions s JOIN tree t ON s.parent = t.id
    )
    """
    var stamps: [Date] = []
    if let row = try Row.fetchOne(
      db,
      sql: tree + """
      SELECT at, duration_ms FROM inferences
      WHERE session IN (SELECT id FROM tree) AND outcome = 'ok'
      ORDER BY at DESC LIMIT 1
      """,
      arguments: [task],
    ) {
      let duration: Int64? = row["duration_ms"]
      stamps.append(try SQLiteDateFormat.date(from: row["at"]).addingTimeInterval(Double(duration ?? 0) / 1000))
    }
    stamps += try String.fetchAll(
      db,
      sql: tree + "SELECT run_progress_at FROM sessions WHERE id IN (SELECT id FROM tree) AND run_progress_at IS NOT NULL",
      arguments: [task],
    ).map(SQLiteDateFormat.date(from:))
    if let posted = try String.fetchOne(
      db,
      sql: """
      SELECT MAX(m.created_at) FROM messages m
      WHERE m.sender_session_id = ?
        AND m.conversation_id = (SELECT conversation_id FROM messages WHERE request_id = ? AND kind = 'request' LIMIT 1)
      """,
      arguments: [task, clock.request.rawValue],
    ) {
      stamps.append(try SQLiteDateFormat.date(from: posted))
    }

    let row = try Row.fetchOne(
      db, sql: "SELECT run_state, run_progress_at, hold, work FROM sessions WHERE id = ?", arguments: [task],
    )!
    let run = SessionRunState(rawValue: row["run_state"])
    // Each wait with its start; a nil start (a script's) predates the anchor,
    // since a script starts before its run_script call completes.
    var waits: [Date?] = []
    if run == .tool {
      waits.append(try (row["run_progress_at"] as String?).map(SQLiteDateFormat.date(from:)))
    }
    // A handler firing holds an owner row while it runs; it is not a wait.
    let workerScript = try String.fetchAll(
      db, sql: "SELECT script_id FROM worker_script_owners WHERE session_id = ?", arguments: [task],
    ).contains { !$0.hasPrefix("handler-") }
    if workerScript || liveScripts.contains(clock.task) { waits.append(nil) }
    var until: Date?
    for timer in try SubscriptionRow.where({ $0.sessionID.eq(task) }).fetchAll(db) {
      guard case .timer(.oneShot, _) = try Sessions.decode(SubscriptionSlot.self, from: timer.payload).kind,
            let due = try timer.nextFireAt.map(SQLiteDateFormat.date(from:)), due > now
      else { continue }
      waits.append(try SQLiteDateFormat.date(from: timer.armedAt))
      until = min(until ?? due, due)
    }
    if let asked = try String.fetchOne(
      db,
      sql: """
      SELECT MIN(r.created_at) FROM messages r WHERE r.sender_session_id = ? AND r.kind = 'request'
        AND NOT EXISTS (SELECT 1 FROM messages f WHERE f.request_id = r.request_id AND f.kind = 'final')
      """,
      arguments: [task],
    ) {
      waits.append(try SQLiteDateFormat.date(from: asked))
    }
    let since: Date? = waits.contains(where: { $0 == nil }) ? nil : waits.compactMap(\.self).min()

    let state: String
    if row["work"] as String == SessionWork.errored.rawValue {
      state = "errored"
    } else if row["hold"] as String == SessionHold.interrupted.rawValue {
      state = "interrupted"
    } else if run == .inference, let since: String = row["run_progress_at"] {
      state = "unknown: inference open since \(since)"
    } else if run == .noRun {
      state = "idle"
    } else {
      state = "unknown"
    }
    return StallSight(
      progress: stamps.max(),
      waiting: !waits.isEmpty,
      since: since,
      until: until,
      state: state,
    )
  }
}
