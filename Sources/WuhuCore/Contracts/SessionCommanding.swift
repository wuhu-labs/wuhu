import Foundation

/// Transport-agnostic contract for issuing commands to a session.
///
/// Commands are intended to be low-latency: they should not wait for agent execution. Their
/// effects are observed via session read models / subscriptions.
public protocol SessionCommanding: Actor {
  /// Enqueue a user steer message (urgent injection at the next steer checkpoint).
  func enqueueSteer(sessionID: SessionID, message: QueuedUserMessage) async throws -> QueueItemID

  /// Cancel a previously enqueued steer message that has not yet been materialized into the transcript.
  func cancelSteer(sessionID: SessionID, id: QueueItemID) async throws

  /// Enqueue a user follow-up message (next-turn input at the follow-up checkpoint).
  func enqueueFollowUp(sessionID: SessionID, message: QueuedUserMessage) async throws -> QueueItemID

  /// Cancel a previously enqueued follow-up message that has not yet been materialized into the transcript.
  func cancelFollowUp(sessionID: SessionID, id: QueueItemID) async throws
}
