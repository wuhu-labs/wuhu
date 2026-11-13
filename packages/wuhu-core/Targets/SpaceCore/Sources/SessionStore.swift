import Dependencies
import TaskLifetime
#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import GRDB
import SessionDomain
import struct SpaceContract.GroupID
import enum SpaceContract.SessionHoldPayload
import enum SpaceContract.SessionWorkPayload

public typealias SessionHold = SpaceContract.SessionHoldPayload
public typealias SessionWork = SpaceContract.SessionWorkPayload

public enum SessionLifecycle: Hashable, Sendable, Codable {
  case live
  case archived(graceExpiresAt: Date)
}

public enum SessionKind: String, Hashable, Sendable, Codable {
  case agent
  case task
}

public struct SessionRecord: Hashable, Sendable, Codable {
  public var id: SessionID
  public var kind: SessionKind
  public var parent: SessionID?
  public var title: String
  public var tags: [String]
  public var createdBy: String
  public var executor: SessionExecutor
  public var createdAt: Date
  public var lastActivityAt: Date
  public var hold: SessionHold
  public var work: SessionWork
  public var errorMessage: String?
  public var lifecycle: SessionLifecycle
  public var group: GroupID

  public init(
    id: SessionID,
    kind: SessionKind,
    parent: SessionID?,
    title: String,
    tags: [String],
    createdBy: String,
    executor: SessionExecutor,
    createdAt: Date,
    lastActivityAt: Date,
    hold: SessionHold,
    work: SessionWork,
    errorMessage: String?,
    lifecycle: SessionLifecycle,
    group: GroupID,
  ) {
    self.id = id
    self.kind = kind
    self.parent = parent
    self.title = title
    self.tags = tags
    self.createdBy = createdBy
    self.executor = executor
    self.createdAt = createdAt
    self.lastActivityAt = lastActivityAt
    self.hold = hold
    self.work = work
    self.errorMessage = errorMessage
    self.lifecycle = lifecycle
    self.group = group
  }
}

public struct SessionQueueEntry: Hashable, Sendable, Codable {
  public var id: Int
  public var input: QueueInput

  public init(id: Int, input: QueueInput) {
    self.id = id
    self.input = input
  }
}

public struct QueueDrain: Hashable, Sendable {
  public var items: [TranscriptItem]
  public var queueTail: Int
  /// The group-observer firings that posted the drained messages or opened their requests.
  public var firings: [String]

  public init(items: [TranscriptItem], queueTail: Int, firings: [String] = []) {
    self.items = items
    self.queueTail = queueTail
    self.firings = firings
  }
}

public struct SessionHydration: Hashable, Sendable, Codable {
  public var generation: Int
  public var record: SessionRecord
  /// The generation's transcript is an older build's typed items, which nothing reads: the session's cell opens a new generation before anything else.
  public var legacy: Bool
  public var queueHead: Int
  public var queueTail: Int
  /// Times the session was resumed: each asks its interrupted or failed step again.
  public var stepTry: Int

  public init(
    generation: Int,
    record: SessionRecord,
    legacy: Bool = false,
    queueHead: Int,
    queueTail: Int,
    stepTry: Int = 0,
  ) {
    self.generation = generation
    self.record = record
    self.legacy = legacy
    self.queueHead = queueHead
    self.queueTail = queueTail
    self.stepTry = stepTry
  }
}

public enum SessionStoreError: Error, Equatable, Sendable {
  public static let humanAgentDirectMessageExplanation = "There is no DM between human and agent. To notify a human, post in your conversation box, optionally specifying the reply target's message ID: it notifies whoever wrote there last and anyone who wrote there in the past 24 hours."

  public static func reportRefusal(_ id: String, violations: [String], left: Int) -> String {
    "final report refused: request \(id) wants JSON matching its schema; " + violations.joined(separator: "; ")
      + (left > 0 ? ". Fix it and report again; \(left) more refusal\(left == 1 ? "" : "s") fail the request." : ". The request has failed.")
  }

  case modelRouteInvalid(group: String, member: String)
  case unknownSession(String)
  case unknownPerson(String)
  case archiveGraceExpired(String)
  case busyForRestart(String)
  case restartOfArchivedSession(String)
  case parentUnavailableForCreation(String)
  case unknownMessage(String)
  case unknownConversation(String)
  case replyTargetInAnotherConversation(String)
  case selfDirectMessage(String)
  case humanAgentDirectMessage
  case taskHasNoBox(String)
  case taskTakesNoHumanInput(String)
  case notTheParent(String)
  case requestAlreadyOpen(String)
  case unknownRequest(String)
  // A final that broke the request's schema; `left` refusals remain, and at
  // zero the request has failed.
  case reportRefused(String, violations: [String], left: Int)
  case unusableTitle(String)
  // The would-be parent, already at the depth limit.
  case tooDeep(String)
  case notInCharge(String, actor: String)
  // Archive and unarchive: not the session, its creator, nor an admin of its group.
  case mayNotArchive(String, actor: String)
}

public struct SessionStore: Sendable {
  public let space: Space
  let taskScope: TaskScope
  let writer: any DatabaseWriter
  let bucket: Bucket
  let dateGen: DateGenerator
  let runtime: SpaceRuntime
  let rng: WithRandomNumberGenerator
}

extension Space {
  public nonisolated var sessions: SessionStore {
    SessionStore(space: self, taskScope: taskScope, writer: writer, bucket: bucket, dateGen: dateGen, runtime: runtime, rng: rng)
  }
}

extension SessionStore {
  public func record(_ id: SessionID) async throws -> SessionRecord {
    let key = id.rawValue
    return try await writer.read { db in
      try Sessions.record(key, in: db)
    }
  }

  public func hydrate(_ id: SessionID) async throws -> SessionHydration {
    let now = SQLiteDateFormat.string(from: dateGen.now)
    return try await writer.read { db in try Sessions.hydrate(id.rawValue, at: now, in: db) }
  }

  public func undrainedInputs(_ id: SessionID) async throws -> [SessionQueueEntry] {
    let key = id.rawValue
    let now = SQLiteDateFormat.string(from: dateGen.now)
    return try await writer.read { db in
      try Sessions.undrained(key, tail: try Sessions.runtime(key, in: db).queueTail, at: now, in: db)
    }
  }
}

extension Sessions {
  /// When the work at hand should give the turn back to what waits for the session: each due input it has not seen allows a grace from when it came due, a person's message to the session itself 10 s, anything else 90 s; the session's own context deliveries allow none of their own. Nil while nothing waits.
  static func yieldDeadline(_ key: String, at now: String, in db: Database) throws -> Date? {
    var deadline: Date?
    for row in try Row.fetchAll(
      db,
      sql: "SELECT payload, COALESCE(due_at, enqueued_at) AS arrived FROM session_queue WHERE session_id = ? AND id > ? AND \(due) ORDER BY id",
      arguments: [key, try runtime(key, in: db).queueTail, now],
    ) {
      guard let grace = try grace(of: try decode(QueueInput.self, from: row["payload"]), to: key, in: db) else { continue }
      let end = try SQLiteDateFormat.date(from: row["arrived"]).addingTimeInterval(grace)
      deadline = min(deadline ?? end, end)
    }
    return deadline
  }

  private static func grace(of input: QueueInput, to session: String, in db: Database) throws -> TimeInterval? {
    switch input {
    case let .message(message):
      guard message.senderSession == nil,
            let conversation = try Conversations.record(message.conversationID.rawValue, in: db)
      else { return 90 }
      switch conversation.kind {
      case .box: return conversation.ownerSession?.rawValue == session ? 10 : 90
      case .dmUser: return 10
      case .users, .dmSession: return 90
      }
    case let .notification(notification):
      return notification.kind == .context ? nil : 90
    }
  }
}

extension SessionStore {
  public func queueHead(_ id: SessionID) async throws -> Int {
    let key = id.rawValue
    let now = SQLiteDateFormat.string(from: dateGen.now)
    return try await writer.read { db in
      let runtime = try Sessions.runtime(key, in: db)
      return Int(try Sessions.queueHead(key, tail: runtime.queueTail, at: now, in: db))
    }
  }
}

extension Sessions {
  static func hydrate(_ key: String, at now: String, in db: Database) throws -> SessionHydration {
    let record = try Sessions.record(key, in: db)
    let runtime = try Sessions.runtime(key, in: db)
    return SessionHydration(
      generation: Int(runtime.generation),
      record: record,
      legacy: try !record.executor.isRetired && Sessions.isLegacy(key, generation: runtime.generation, in: db),
      queueHead: Int(try Sessions.queueHead(key, tail: runtime.queueTail, at: now, in: db)),
      queueTail: Int(runtime.queueTail),
      stepTry: Int(runtime.stepTry),
    )
  }
}
