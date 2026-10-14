#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import SessionDomain

public protocol SessionExecutionOwnerClient: Sendable {
  func modelRoute(_ id: SessionID) async throws -> SessionModelRoute?
  func establishModelRoute(_ id: SessionID, route: SessionModelRoute) async throws -> SessionModelRoute
  func record(_ id: SessionID) async throws -> SessionRecord
  func hydrate(_ id: SessionID) async throws -> SessionHydration
  func enqueue(_ id: SessionID, input: QueueInput) async throws -> Int
  func drainQueue(_ id: SessionID) async throws -> QueueDrain
  func discardPendingCacheWarming(_ id: SessionID) async throws -> Transcript
  func append(_ id: SessionID, items: [TranscriptItem], transcript: Transcript, completingCompactRequest: CompactRequestClaim?) async throws
  func scopeContext(_ id: SessionID, toolCallID: ToolCallID) async throws -> ScopeContext?
  func queueHead(_ id: SessionID) async throws -> Int
  func pendingCommand(_ id: SessionID) async throws -> SessionCommand?
  func claimCompactRequest(_ id: SessionID, generation: Int) async throws -> CompactRequestClaim?
  func writePortableHandoff(_ id: SessionID, expectedGeneration: Int, source: Transcript, transcript: Transcript) async throws -> Transcript
  func writeCompaction(_ id: SessionID, closing: ToolResultItem?, head: GenerationHead, kept: Range<Int>?, completingCompactRequest: CompactRequestClaim?) async throws -> Transcript
  func markInterrupted(_ id: SessionID) async throws
  func markResumed(_ id: SessionID) async throws
  func markErrored(_ id: SessionID, message: String) async throws
  func archive(_ id: SessionID, grace: Duration) async throws -> Date
  func unarchive(_ id: SessionID) async throws
  func restart(_ id: SessionID, executor: SessionExecutor?, note: String?, modelRoute: SessionModelRoute?) async throws -> SessionRestart
  func registeredSubscriptions(_ id: SessionID) async throws -> (ids: Set<SubscriptionID>, handlers: Set<SubscriptionID>)
}

extension SessionExecutionOwnerClient {
  public func restart(_ id: SessionID, executor: SessionExecutor?, note: String?) async throws -> SessionRestart {
    try await restart(id, executor: executor, note: note, modelRoute: nil)
  }
}
