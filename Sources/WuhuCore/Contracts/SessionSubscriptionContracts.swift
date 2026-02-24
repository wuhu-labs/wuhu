import Foundation
import WuhuAPI

/// Parameters for establishing a session subscription.
///
/// All cursors are optional — nil means "from scratch."
public struct SessionSubscriptionRequest: Sendable, Hashable, Codable {
  public var transcriptSince: TranscriptCursor?
  public var transcriptPageSize: Int

  public var systemSince: QueueCursor?
  public var steerSince: QueueCursor?
  public var followUpSince: QueueCursor?

  public init(
    transcriptSince: TranscriptCursor? = nil,
    transcriptPageSize: Int = 200,
    systemSince: QueueCursor? = nil,
    steerSince: QueueCursor? = nil,
    followUpSince: QueueCursor? = nil,
  ) {
    self.transcriptSince = transcriptSince
    self.transcriptPageSize = transcriptPageSize
    self.systemSince = systemSince
    self.steerSince = steerSince
    self.followUpSince = followUpSince
  }
}

/// Initial payload for a subscription: current settings/status plus catch-up data.
public struct SessionInitialState: Sendable, Hashable, Codable {
  public var settings: SessionSettingsSnapshot
  public var status: SessionStatusSnapshot

  public var transcript: [WuhuSessionEntry]

  public var systemUrgent: SystemUrgentQueueBackfill
  public var steer: UserQueueBackfill
  public var followUp: UserQueueBackfill

  /// Accumulated streaming text if inference is mid-flight at subscription time.
  /// Not part of the stable patch — ephemeral state for reconnection.
  public var inflightStreamText: String?

  public init(
    settings: SessionSettingsSnapshot,
    status: SessionStatusSnapshot,
    transcript: [WuhuSessionEntry],
    systemUrgent: SystemUrgentQueueBackfill,
    steer: UserQueueBackfill,
    followUp: UserQueueBackfill,
    inflightStreamText: String? = nil,
  ) {
    self.settings = settings
    self.status = status
    self.transcript = transcript
    self.systemUrgent = systemUrgent
    self.steer = steer
    self.followUp = followUp
    self.inflightStreamText = inflightStreamText
  }
}

/// Live session events emitted after the initial state is produced.
public enum SessionEvent: Sendable, Hashable, Codable {
  case transcriptAppended([WuhuSessionEntry])
  case systemUrgentQueue(cursor: QueueCursor, entries: [SystemUrgentQueueJournalEntry])
  case userQueue(cursor: QueueCursor, entries: [UserQueueJournalEntry])
  case settingsUpdated(SessionSettingsSnapshot)
  case statusUpdated(SessionStatusSnapshot)

  /// Inference streaming has begun. Ephemeral — not persisted.
  case streamBegan
  /// An ephemeral text delta during inference streaming.
  case streamDelta(String)
  /// Inference streaming has ended. Ephemeral — not persisted.
  case streamEnded
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
  func subscribe(sessionID: SessionID, since: SessionSubscriptionRequest) async throws -> SessionSubscription
}
