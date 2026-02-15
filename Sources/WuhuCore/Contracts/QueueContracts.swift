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

/// Backfill request for a queue lane.
public enum QueueBackfillRequest: Sendable, Hashable, Codable {
  /// Request a full pending snapshot for initial load.
  case snapshot
  /// Request journal entries since a cursor for catch-up.
  case since(QueueCursor)
}

public enum UserQueueBackfill: Sendable, Hashable, Codable {
  /// Full snapshot of pending items, plus a cursor representing "now".
  case snapshot(cursor: QueueCursor, pending: [UserQueuePendingItem])
  /// Journal entries since a cursor, plus a cursor representing "now".
  ///
  /// Implementations may coalesce away transient enqueue→materialize pairs that complete entirely
  /// within the backfill window, to avoid transmitting already-processed work as "pending".
  case journal(cursor: QueueCursor, entries: [UserQueueJournalEntry])
}

public enum SystemUrgentQueueBackfill: Sendable, Hashable, Codable {
  case snapshot(cursor: QueueCursor, pending: [SystemUrgentPendingItem])
  case journal(cursor: QueueCursor, entries: [SystemUrgentQueueJournalEntry])
}

