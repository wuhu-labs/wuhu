#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import JSONValue
import OrderedCollections
import SessionDomain
import SpaceCore
import struct WuhuAI.AssistantMessage
import struct WuhuAI.AssistantMessageMetadata

struct SessionRepo: Sendable {
  var owner: any SessionExecutionOwnerClient
  var id: SessionID
  var hydrationRead: @Sendable (any SessionExecutionOwnerClient, SessionID) async throws -> SessionHydration = { try await $0.hydrate($1) }
  var queueHeadRead: @Sendable (any SessionExecutionOwnerClient, SessionID) async throws -> Int = { try await $0.queueHead($1) }
  var pendingCommandRead: @Sendable (any SessionExecutionOwnerClient, SessionID) async throws -> SessionCommand? = { try await $0.pendingCommand($1) }
  var compactClaimWrite: @Sendable (any SessionExecutionOwnerClient, SessionID, Int) async throws -> CompactRequestClaim? = { try await $0.claimCompactRequest($1, generation: $2) }
  var archiveWrite: @Sendable (any SessionExecutionOwnerClient, SessionID, Duration) async throws -> Date = { try await $0.archive($1, grace: $2) }

  func registeredSubscriptions() async throws -> (ids: Set<SubscriptionID>, handlers: Set<SubscriptionID>) {
    try await owner.registeredSubscriptions(id)
  }

  func hydrate() async throws -> SessionHydration {
    try await hydrationRead(owner, id)
  }

  func enqueue(input: QueueInput) async throws -> Int {
    try await owner.enqueue(id, input: input)
  }

  func drainQueue() async throws -> QueueDrain {
    try await owner.drainQueue(id)
  }

  func discardPendingCacheWarming() async throws -> Transcript {
    try await owner.discardPendingCacheWarming(id)
  }

  func append(_ items: [TranscriptItem], transcript: Transcript, completingCompactRequest: CompactRequestClaim? = nil) async throws {
    try await owner.append(id, items: items, transcript: transcript, completingCompactRequest: completingCompactRequest)
  }

  func scopeContext(_ callID: ToolCallID) async throws -> ScopeContext? {
    try await owner.scopeContext(id, toolCallID: callID)
  }

  func queueHead() async throws -> Int {
    try await queueHeadRead(owner, id)
  }

  func pendingCommand() async throws -> SessionCommand? {
    try await pendingCommandRead(owner, id)
  }

  func claimCompactRequest(generation: Int) async throws -> CompactRequestClaim? {
    try await compactClaimWrite(owner, id, generation)
  }

  func writePortableHandoff(expectedGeneration: Int, source: Transcript, transcript: Transcript, transition: ModelRouteTransition? = nil) async throws -> Transcript {
    try await owner.writePortableHandoff(id, expectedGeneration: expectedGeneration, source: source, transcript: transcript, transition: transition)
  }

  func writeCompaction(
    closing: ToolResultItem?,
    head: GenerationHead,
    kept: Range<Int>?,
    completingCompactRequest: CompactRequestClaim? = nil,
    transition: ModelRouteTransition? = nil,
  ) async throws -> Transcript {
    try await owner.writeCompaction(id, closing: closing, head: head, kept: kept, completingCompactRequest: completingCompactRequest, transition: transition)
  }

  func markInterrupted() async throws {
    try await owner.markInterrupted(id)
  }

  func markResumed() async throws {
    try await owner.markResumed(id)
  }

  func markCompacting(_ active: Bool) async throws {
    try await owner.markCompacting(id, active: active)
  }

  func markErrored(errorDescription: String) async throws {
    try await owner.markErrored(id, message: errorDescription)
  }

  func archive(grace: Duration) async throws -> Date {
    try await archiveWrite(owner, id, grace)
  }

  func unarchive() async throws {
    try await owner.unarchive(id)
  }

  func restart(executor: SessionExecutor?, note: String?, modelRoute: SessionModelRoute?) async throws -> SessionRestart {
    try await owner.restart(id, executor: executor, note: note, modelRoute: modelRoute)
  }
}
