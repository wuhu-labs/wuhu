import Foundation

/// A user message that can be queued for steer or follow-up injection.
public struct QueuedUserMessage: Sendable, Hashable, Codable {
  public var author: Author
  public var content: MessageContent

  public init(author: Author, content: MessageContent) {
    self.author = author
    self.content = content
  }
}

/// Queue lanes with different semantics.
public enum UserQueueLane: String, Sendable, Hashable, Codable {
  case steer
  case followUp
}

/// A system-urgent input that should be injected at the same checkpoint as steer,
/// but is not a user steer message and is not cancelable.
public struct SystemUrgentInput: Sendable, Hashable, Codable {
  public var source: SystemUrgentSource
  public var content: MessageContent

  public init(source: SystemUrgentSource, content: MessageContent) {
    self.source = source
    self.content = content
  }
}

public enum SystemUrgentSource: Sendable, Hashable, Codable {
  case asyncBashCallback
  case asyncTaskNotification
  case other(String)
}

public struct UserQueuePendingItem: Sendable, Hashable, Codable {
  public var id: QueueItemID
  public var enqueuedAt: Date
  public var message: QueuedUserMessage

  public init(id: QueueItemID, enqueuedAt: Date, message: QueuedUserMessage) {
    self.id = id
    self.enqueuedAt = enqueuedAt
    self.message = message
  }
}

public struct SystemUrgentPendingItem: Sendable, Hashable, Codable {
  public var id: QueueItemID
  public var enqueuedAt: Date
  public var input: SystemUrgentInput

  public init(id: QueueItemID, enqueuedAt: Date, input: SystemUrgentInput) {
    self.id = id
    self.enqueuedAt = enqueuedAt
    self.input = input
  }
}

/// Journal entries represent the durable history of queue state transitions.
///
/// For user queues, the external command surface includes enqueue/cancel, while materialization
/// is an internal action performed by the session actor/agent loop.
public enum UserQueueJournalEntry: Sendable, Hashable, Codable {
  case enqueued(lane: UserQueueLane, item: UserQueuePendingItem)
  case canceled(lane: UserQueueLane, id: QueueItemID, at: Date)
  case materialized(lane: UserQueueLane, id: QueueItemID, transcriptEntryID: TranscriptEntryID, at: Date)
}

/// System-urgent queue has no cancel operation.
public enum SystemUrgentQueueJournalEntry: Sendable, Hashable, Codable {
  case enqueued(item: SystemUrgentPendingItem)
  case materialized(id: QueueItemID, transcriptEntryID: TranscriptEntryID, at: Date)
}

/// Catch-up data for a user queue lane.
///
/// When `since` is nil, the response is a full snapshot. When a cursor is provided,
/// the response is journal entries since that cursor. Implementations may coalesce
/// transient enqueue→materialize pairs that complete within the window.
public struct UserQueueBackfill: Sendable, Hashable, Codable {
  public var cursor: QueueCursor
  public var pending: [UserQueuePendingItem]
  public var journal: [UserQueueJournalEntry]

  public init(cursor: QueueCursor, pending: [UserQueuePendingItem], journal: [UserQueueJournalEntry]) {
    self.cursor = cursor
    self.pending = pending
    self.journal = journal
  }
}

/// Catch-up data for the system-urgent queue lane.
public struct SystemUrgentQueueBackfill: Sendable, Hashable, Codable {
  public var cursor: QueueCursor
  public var pending: [SystemUrgentPendingItem]
  public var journal: [SystemUrgentQueueJournalEntry]

  public init(cursor: QueueCursor, pending: [SystemUrgentPendingItem], journal: [SystemUrgentQueueJournalEntry]) {
    self.cursor = cursor
    self.pending = pending
    self.journal = journal
  }
}
