import Foundation

/// Transport-agnostic contract for issuing commands to a session.
///
/// Commands are low-latency: they return an ID immediately and do not wait
/// for agent execution. Effects are observed via subscription.
public protocol SessionCommanding: Actor {
  /// Enqueue a user message into the specified lane.
  func enqueue(sessionID: SessionID, message: QueuedUserMessage, lane: UserQueueLane) async throws -> QueueItemID

  /// Cancel a previously enqueued message that has not yet been materialized.
  func cancel(sessionID: SessionID, id: QueueItemID, lane: UserQueueLane) async throws
}
