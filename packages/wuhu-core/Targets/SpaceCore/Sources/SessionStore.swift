import struct ClaudeStream.ClaudeCodeLog
import Dependencies
import Foundation
import GRDB
import SessionDomain
import struct SpaceContract.GroupID

public enum SessionHold: String, Hashable, Sendable {
  case normal
  case interrupted
}

public enum SessionWork: String, Hashable, Sendable {
  case noWork = "no_work"
  case hasWork = "has_work"
  case errored
}

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
  case claudeCode(ClaudeCodeLog)
}

public struct SessionHydration: Hashable, Sendable {
  public var record: SessionRecord
  public var transcript: SessionTranscript
  public var undrained: [SessionQueueEntry]
  public var queueHead: Int
  public var queueTail: Int
}

public enum SessionStoreError: Error, Equatable, Sendable {
  case unknownSession(String)
  case archiveGraceExpired(String)
  case busyForRestart(String)
  case restartOfArchivedSession(String)
  case unknownMessage(String)
  case unknownConversation(String)
  case replyTargetInAnotherConversation(String)
  case selfDirectMessage(String)
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
  let writer: any DatabaseWriter
  let blobs: BlobStore
  let dateGen: DateGenerator
  let broadcast: FSBroadcast
  let signals: WorkSignals
  let rng: WithRandomNumberGenerator
}

extension Space {
  public nonisolated var sessions: SessionStore {
    SessionStore(writer: writer, blobs: blobs, dateGen: dateGen, broadcast: broadcast, signals: workSignals, rng: rng)
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
      case .kernel, .contractor: try Sessions.transcript(key, in: db)
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
      case .kernel: .kernel(try Sessions.kernelTranscript(key, in: db))
      case .contractor: .kernel(try Sessions.transcript(key, in: db))
      case .claudeCode: .claudeCode(try Sessions.claudeCodeLog(key, in: db))
      }
      return SessionHydration(
        record: record,
        transcript: transcript,
        undrained: try Sessions.undrained(key, tail: runtime.queueTail, in: db),
        queueHead: Int(try Sessions.queueHead(key, tail: runtime.queueTail, in: db)),
        queueTail: Int(runtime.queueTail),
      )
    }
    guard case let .claudeCode(log) = hydration.transcript else { return hydration }
    var restored = hydration
    restored.transcript = .claudeCode(try await restoringImages(log))
    return restored
  }

  // The session service's boot scan: a session left from the removed
  // contractor executor is never materialized by it.
  public func bootSessions() async throws -> [SessionID] {
    try await writer.read { db in
      // A task's park wake lives only in its loaded actor, computed from its
      // session environment; loading every task with an open request is what
      // schedules it again after a restart.
      try Row.fetchAll(
        db,
        sql: """
        SELECT id, NOT (work = 'has_work' OR id IN (SELECT session_id FROM session_commands)) AS parked
        FROM sessions
        WHERE lifecycle = 'live' AND executor IN ('kernel', 'claude-code')
          AND (work = 'has_work' OR id IN (SELECT session_id FROM session_commands) OR (kind = 'task' AND work = 'no_work'))
        ORDER BY allocation
        """,
      ).compactMap { row -> SessionID? in
        let key: String = row["id"]
        guard row["parked"] as Bool else { return SessionID(key) }
        return try Sessions.settleState(key, in: db).openRequests.isEmpty ? nil : SessionID(key)
      }
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
