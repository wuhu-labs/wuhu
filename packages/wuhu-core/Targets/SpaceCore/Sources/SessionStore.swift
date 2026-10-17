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

public enum SessionLifecycle: Hashable, Sendable {
  case live
  case archived(graceExpiresAt: Date)
}

public enum SessionKind: String, Hashable, Sendable, Codable {
  case agent
  case task
}

public struct SessionRecord: Hashable, Sendable {
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

public struct SessionQueueEntry: Hashable, Sendable {
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

  public init(items: [TranscriptItem], queueTail: Int) {
    self.items = items
    self.queueTail = queueTail
  }
}

public enum SessionTranscript: Hashable, Sendable {
  case kernel(Transcript)
}

public struct SessionHydration: Hashable, Sendable {
  public var generation: Int
  public var record: SessionRecord
  public var transcript: SessionTranscript
  public var undrained: [SessionQueueEntry]
  public var queueHead: Int
  public var queueTail: Int

  public init(
    generation: Int,
    record: SessionRecord,
    transcript: SessionTranscript,
    undrained: [SessionQueueEntry],
    queueHead: Int,
    queueTail: Int,
  ) {
    self.generation = generation
    self.record = record
    self.transcript = transcript
    self.undrained = undrained
    self.queueHead = queueHead
    self.queueTail = queueTail
  }
}

public enum SessionStoreError: Error, Equatable, Sendable {
  public static let humanAgentDirectMessageExplanation = "There is no DM between human and agent. If you want to notify a human that has talked in your conversation box, simply post that box, optionally specifying the reply target's message ID."

  case modelRouteInvalid(group: String, member: String)
  case unknownSession(String)
  case archiveGraceExpired(String)
  case busyForRestart(String)
  case requestDeadlineWithoutFireDate(String)
  case restartOfArchivedSession(String)
  case parentUnavailableForCreation(String)
  case unknownMessage(String)
  case unknownConversation(String)
  case replyTargetInAnotherConversation(String)
  case selfDirectMessage(String)
  case humanAgentDirectMessage
  case taskHasNoBox(String)
  case taskTakesNoHumanInput(String)
  case noParent(String)
  case notTheParent(String)
  case requestAlreadyOpen(String)
  case unknownRequest(String)
  case unusableTitle(String)
  // The would-be parent, already at the depth limit.
  case tooDeep(String)
  case notInCharge(String, actor: String)
  // Archive and unarchive: not the session, its creator, nor an admin of its group.
  case mayNotArchive(String, actor: String)
}

public struct ForeignReceipt: Error, Equatable, Sendable {
  public var toolCallID: ToolCallID
}

public struct SessionStore: Sendable {
  let taskScope: TaskScope
  let writer: any DatabaseWriter
  let blobs: BlobStore
  let dateGen: DateGenerator
  let broadcast: FSBroadcast
  let signals: WorkSignals
  let archiveReservations: ArchiveReservations
  let rng: WithRandomNumberGenerator
}

extension Space {
  public nonisolated var sessions: SessionStore {
    SessionStore(taskScope: taskScope, writer: writer, blobs: blobs, dateGen: dateGen, broadcast: broadcast, signals: workSignals, archiveReservations: archiveReservations, rng: rng)
  }
}

extension SessionStore {
  public func record(_ id: SessionID) async throws -> SessionRecord {
    let key = id.rawValue
    return try await writer.read { db in
      try Sessions.record(key, in: db)
    }
  }

  public func transcript(_ id: SessionID) async throws -> Transcript {
    let key = id.rawValue
    return try await writer.read { db in
      switch try Sessions.record(key, in: db).executor {
      case .kernel, .modelGroup, .contractor: try Sessions.transcript(key, in: db)
      case .claudeCode: Transcript()
      }
    }
  }

  public func hydrate(_ id: SessionID) async throws -> SessionHydration {
    let key = id.rawValue
    let hydration = try await writer.read { db in
      let record = try Sessions.record(key, in: db)
      let runtime = try Sessions.runtime(key, in: db)
      let transcript: SessionTranscript = switch record.executor {
      case .kernel, .modelGroup: .kernel(try Sessions.kernelTranscript(key, in: db))
      case .contractor: .kernel(try Sessions.transcript(key, in: db))
      case .claudeCode: throw ExecutorUnavailableError()
      }
      return SessionHydration(
        generation: Int(runtime.generation),
        record: record,
        transcript: transcript,
        undrained: try Sessions.undrained(key, tail: runtime.queueTail, in: db),
        queueHead: Int(try Sessions.queueHead(key, tail: runtime.queueTail, in: db)),
        queueTail: Int(runtime.queueTail),
      )
    }
    return hydration
  }

  /// Failure handling runs in the read snapshot: collect errors here and handle them after the scan, without reentering the store. Returning skips the failed session; throwing aborts the scan.
  public func bootSessions(
    onFailure: @escaping @Sendable (SessionID, any Error) throws -> Void = { _, error in throw error },
  ) async throws -> [SessionID] {
    try await writer.read { db in
      try Row.fetchAll(
        db,
        sql: """
        SELECT id, NOT (work = 'has_work' OR id IN (SELECT session_id FROM session_commands)) AS parked
        FROM sessions
        WHERE lifecycle = 'live' AND executor IN ('kernel', 'claude-code')
          AND (executor = 'claude-code' OR work = 'has_work' OR id IN (SELECT session_id FROM session_commands) OR work = 'no_work')
        ORDER BY allocation
        """,
      ).compactMap { row -> SessionID? in
        let key: String = row["id"]
        let id = SessionID(key)
        do {
          try Sessions.record(key, in: db).executor.requireSupported()
          guard row["parked"] as Bool else { return id }
          return try Sessions.settleState(key, in: db).openRequests.isEmpty ? nil : id
        } catch {
          try onFailure(id, error)
          return nil
        }
      }
    }
  }

  public func undrainedInputs(_ id: SessionID) async throws -> [SessionQueueEntry] {
    let key = id.rawValue
    return try await writer.read { db in
      try Sessions.undrained(key, tail: try Sessions.runtime(key, in: db).queueTail, in: db)
    }
  }

  /// For each urgency, the earliest item in the session's queue that the
  /// model has not seen yet, most urgent first; empty while there is none:
  /// now, and again after every change.
  public func observePendingArrivals(_ id: SessionID) -> some AsyncSequence<[PendingArrival], any Error> & Sendable {
    let key = id.rawValue
    return ValueObservation
      .tracking { db in try Self.pendingArrivals(key, in: db) }
      .removeDuplicates()
      .values(in: writer, bufferingPolicy: .bufferingNewest(1))
  }

  static func pendingArrivals(_ key: String, in db: Database) throws -> [PendingArrival] {
    var earliest: [ArrivalUrgency: Date] = [:]
    for row in try Row.fetchAll(
      db,
      sql: "SELECT payload, enqueued_at FROM session_queue WHERE session_id = ? AND id > ? ORDER BY id",
      arguments: [key, try Sessions.runtime(key, in: db).queueTail],
    ) {
      guard let urgency = try urgency(of: try Sessions.decode(QueueInput.self, from: row["payload"]), to: key, in: db),
            earliest[urgency] == nil
      else { continue }
      earliest[urgency] = try SQLiteDateFormat.date(from: row["enqueued_at"])
    }
    return earliest.map { PendingArrival(urgency: $0.key, arrivedAt: $0.value) }.sorted { $0.urgency < $1.urgency }
  }

  // A person's message in the session's own box or in a person's DM with it
  // is direct; any other message or notification is other. Context
  // deliveries are the session's own housekeeping and count as nothing.
  private static func urgency(of input: QueueInput, to session: String, in db: Database) throws -> ArrivalUrgency? {
    switch input {
    case let .message(message):
      guard message.senderSession == nil,
            let conversation = try Conversations.record(message.conversationID.rawValue, in: db)
      else { return .other }
      switch conversation.kind {
      case .box: return conversation.ownerSession?.rawValue == session ? .direct : .other
      case .dmUser: return .direct
      case .users, .dmSession: return .other
      }
    case let .notification(notification):
      return notification.kind == .context ? nil : .other
    }
  }

  public func queueHead(_ id: SessionID) async throws -> Int {
    let key = id.rawValue
    return try await writer.read { db in
      let runtime = try Sessions.runtime(key, in: db)
      return Int(try Sessions.queueHead(key, tail: runtime.queueTail, in: db))
    }
  }

  public func receipt(_ id: SessionID, toolCallID: ToolCallID) async throws -> ToolResultPayload? {
    let key = id.rawValue
    return try await writer.read { db in
      try Sessions.receipt(key, toolCallID: toolCallID.rawValue, in: db)
    }
  }
}

extension SessionStore {
  public func workSignals() -> WorkSignalSubscription {
    signals.subscribe()
  }
}
