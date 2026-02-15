import Foundation

/// Backfill parameters for establishing a session subscription.
///
/// Intended to map cleanly to HTTP query params like `?after=` and `?steerQueueSince=`.
public struct SessionBackfillRequest: Sendable, Hashable, Codable {
  public var transcriptAfter: TranscriptCursor?
  public var transcriptPageSize: Int

  public var systemUrgent: QueueBackfillRequest
  public var steer: QueueBackfillRequest
  public var followUp: QueueBackfillRequest

  public init(
    transcriptAfter: TranscriptCursor? = nil,
    transcriptPageSize: Int = 200,
    systemUrgent: QueueBackfillRequest = .snapshot,
    steer: QueueBackfillRequest = .snapshot,
    followUp: QueueBackfillRequest = .snapshot
  ) {
    self.transcriptAfter = transcriptAfter
    self.transcriptPageSize = transcriptPageSize
    self.systemUrgent = systemUrgent
    self.steer = steer
    self.followUp = followUp
  }
}

/// Initial payload for a subscription: current settings/status plus catch-up data.
public struct SessionInitialState: Sendable, Hashable, Codable {
  public var settings: SessionSettingsSnapshot
  public var status: SessionStatusSnapshot

  public var transcriptPages: [TranscriptPage]

  public var systemUrgent: SystemUrgentQueueBackfill
  public var steer: UserQueueBackfill
  public var followUp: UserQueueBackfill

  public init(
    settings: SessionSettingsSnapshot,
    status: SessionStatusSnapshot,
    transcriptPages: [TranscriptPage],
    systemUrgent: SystemUrgentQueueBackfill,
    steer: UserQueueBackfill,
    followUp: UserQueueBackfill
  ) {
    self.settings = settings
    self.status = status
    self.transcriptPages = transcriptPages
    self.systemUrgent = systemUrgent
    self.steer = steer
    self.followUp = followUp
  }
}

/// Live session events emitted after the initial state is produced.
public enum SessionEvent: Sendable, Hashable, Codable {
  case transcriptAppended(TranscriptPage)
  case systemUrgentQueue(cursor: QueueCursor, entries: [SystemUrgentQueueJournalEntry])
  case userQueue(cursor: QueueCursor, entries: [UserQueueJournalEntry])
  case settingsUpdated(SessionSettingsSnapshot)
  case statusUpdated(SessionStatusSnapshot)
}

/// A subscription established with "subscribe first, then backfill" semantics.
///
/// Implementations should ensure the caller can send `initial` and then consume `events` without
/// missing or duplicating updates that occur between subscription establishment and initial backfill.
public struct SessionSubscription: Sendable {
  public var initial: SessionInitialState
  public var events: AsyncThrowingStream<SessionEvent, Error>

  public init(initial: SessionInitialState, events: AsyncThrowingStream<SessionEvent, Error>) {
    self.initial = initial
    self.events = events
  }
}

/// Transport-agnostic "single stream" contract, suitable for an SSE endpoint.
public protocol SessionSubscribing: Actor {
  func subscribe(sessionID: SessionID, backfill: SessionBackfillRequest) async throws -> SessionSubscription
}

