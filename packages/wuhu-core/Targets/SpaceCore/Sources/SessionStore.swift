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
    try spaceCell.sessionRecord(id)
  }

  public func hydrate(_ id: SessionID) async throws -> SessionHydration {
    try spaceCell.sessionHydration(id, at: dateGen.now)
  }

  public func undrainedInputs(_ id: SessionID) async throws -> [SessionQueueEntry] {
    try spaceCell.sessionInputs(id, at: dateGen.now)
  }
}

extension SessionStore {
  public func queueHead(_ id: SessionID) async throws -> Int {
    try spaceCell.sessionQueueHead(id, at: dateGen.now)
  }
}
