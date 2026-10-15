#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import SessionDomain

public struct InProcessSessionExecutionOwnerClient: SessionExecutionOwnerClient {
  private let sessions: SessionStore

  public init(sessions: SessionStore) {
    self.sessions = sessions
  }

  public func record(_ id: SessionID) async throws -> SessionRecord {
    try await sessions.record(id)
  }

  public func modelRoute(_ id: SessionID) async throws -> SessionModelRoute? {
    try await sessions.modelRoute(id)
  }

  public func updateModelRouteFailure(_ id: SessionID, expectedEpoch: String, failure: ModelRouteFailure?) async throws {
    try await sessions.updateModelRouteFailure(id, expectedEpoch: expectedEpoch, failure: failure)
  }

  public func establishModelRoute(_ id: SessionID, route: SessionModelRoute) async throws -> SessionModelRoute {
    try await sessions.establishModelRoute(id, route: route)
  }

  public func hydrate(_ id: SessionID) async throws -> SessionHydration {
    try await sessions.hydrate(id)
  }

  public func enqueue(_ id: SessionID, input: QueueInput) async throws -> Int {
    try await sessions.enqueue(id, input: input)
  }

  public func drainQueue(_ id: SessionID) async throws -> QueueDrain {
    try await sessions.drainQueue(id)
  }

  public func discardPendingCacheWarming(_ id: SessionID) async throws -> Transcript {
    try await sessions.discardPendingCacheWarming(id)
  }

  public func append(_ id: SessionID, items: [TranscriptItem], transcript: Transcript, completingCompactRequest: CompactRequestClaim?) async throws {
    try await sessions.append(id, items: items, transcript: transcript, completingCompactRequest: completingCompactRequest)
  }

  public func scopeContext(_ id: SessionID, toolCallID: ToolCallID) async throws -> ScopeContext? {
    try await sessions.scopeContext(id, toolCallID: toolCallID)
  }

  public func queueHead(_ id: SessionID) async throws -> Int {
    try await sessions.queueHead(id)
  }

  public func pendingCommand(_ id: SessionID) async throws -> SessionCommand? {
    try await sessions.pendingCommand(id)
  }

  public func claimCompactRequest(_ id: SessionID, generation: Int) async throws -> CompactRequestClaim? {
    try await sessions.claimCompactRequest(id, generation: generation)
  }

  public func writePortableHandoff(_ id: SessionID, expectedGeneration: Int, source: Transcript, transcript: Transcript, transition: ModelRouteTransition? = nil) async throws -> Transcript {
    try await sessions.writePortableHandoff(id, expectedGeneration: expectedGeneration, source: source, transcript: transcript, transition: transition)
  }

  public func writeCompaction(_ id: SessionID, closing: ToolResultItem?, head: GenerationHead, kept: Range<Int>?, completingCompactRequest: CompactRequestClaim?, transition: ModelRouteTransition? = nil) async throws -> Transcript {
    try await sessions.writeCompaction(id, closing: closing, head: head, kept: kept, completingCompactRequest: completingCompactRequest, transition: transition)
  }

  public func markInterrupted(_ id: SessionID) async throws {
    try await sessions.markInterrupted(id)
  }

  public func markResumed(_ id: SessionID) async throws {
    try await sessions.markResumed(id)
  }

  public func markErrored(_ id: SessionID, message: String) async throws {
    try await sessions.markErrored(id, message: message)
  }

  public func markCompacting(_ id: SessionID, active: Bool) async throws {
    try await sessions.markCompacting(id, active: active)
  }

  public func archive(_ id: SessionID, grace: Duration) async throws -> Date {
    try await sessions.archive(id, grace: grace)
  }

  public func unarchive(_ id: SessionID) async throws {
    try await sessions.unarchive(id)
  }

  public func restart(_ id: SessionID, executor: SessionExecutor?, note: String?, modelRoute: SessionModelRoute? = nil) async throws -> SessionRestart {
    try await sessions.restart(id, executor: executor, note: note, modelRoute: modelRoute)
  }

  public func registeredSubscriptions(_ id: SessionID) async throws -> (ids: Set<SubscriptionID>, handlers: Set<SubscriptionID>) {
    try await sessions.registeredSubscriptions(id)
  }
}
