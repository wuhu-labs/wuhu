#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import Credentials
import ExecutionOwner
import InferenceKit
import SessionDomain
import SpaceContract
import SpaceCore

extension InProcessToolOwnerClient {
  public var tracesAttempts: Bool { executionOwner.tracesAttempts }

  public func openAttemptTrace(_ id: UUID) async throws -> AttemptTraceSink {
    try await executionOwner.openAttemptTrace(id)
  }

  public func record(_ id: SessionID) async throws -> SessionRecord {
    try await executionOwner.record(id)
  }

  public func modelRoute(_ id: SessionID) async throws -> SessionModelRoute? {
    try await executionOwner.modelRoute(id)
  }

  public func updateModelRouteFailure(_ id: SessionID, expectedEpoch: String, failure: ModelRouteFailure?) async throws {
    try await executionOwner.updateModelRouteFailure(id, expectedEpoch: expectedEpoch, failure: failure)
  }

  public func establishModelRoute(_ id: SessionID, route: SessionModelRoute) async throws -> SessionModelRoute {
    try await executionOwner.establishModelRoute(id, route: route)
  }

  public func hydrate(_ id: SessionID) async throws -> SessionHydration {
    try await executionOwner.hydrate(id)
  }

  public func enqueue(_ id: SessionID, input: QueueInput) async throws -> Int {
    try await executionOwner.enqueue(id, input: input)
  }

  public func drainQueue(_ id: SessionID) async throws -> QueueDrain {
    try await executionOwner.drainQueue(id)
  }

  public func discardPendingCacheWarming(_ id: SessionID) async throws -> Transcript {
    try await executionOwner.discardPendingCacheWarming(id)
  }

  public func append(_ id: SessionID, items: [TranscriptItem], transcript: Transcript, completingCompactRequest: CompactRequestClaim?) async throws {
    try await executionOwner.append(id, items: items, transcript: transcript, completingCompactRequest: completingCompactRequest)
  }

  public func scopeContext(_ id: SessionID, toolCallID: ToolCallID) async throws -> ScopeContext? {
    try await executionOwner.scopeContext(id, toolCallID: toolCallID)
  }

  public func queueHead(_ id: SessionID) async throws -> Int {
    try await executionOwner.queueHead(id)
  }

  public func pendingCommand(_ id: SessionID) async throws -> SessionCommand? {
    try await executionOwner.pendingCommand(id)
  }

  public func claimCompactRequest(_ id: SessionID, generation: Int) async throws -> CompactRequestClaim? {
    try await executionOwner.claimCompactRequest(id, generation: generation)
  }

  public func writePortableHandoff(_ id: SessionID, expectedGeneration: Int, source: Transcript, transcript: Transcript, transition: ModelRouteTransition? = nil) async throws -> Transcript {
    try await executionOwner.writePortableHandoff(id, expectedGeneration: expectedGeneration, source: source, transcript: transcript, transition: transition)
  }

  public func writeCompaction(_ id: SessionID, closing: ToolResultItem?, head: GenerationHead, kept: Range<Int>?, completingCompactRequest: CompactRequestClaim?, transition: ModelRouteTransition? = nil) async throws -> Transcript {
    try await executionOwner.writeCompaction(id, closing: closing, head: head, kept: kept, completingCompactRequest: completingCompactRequest, transition: transition)
  }

  public func markInterrupted(_ id: SessionID) async throws {
    try await executionOwner.markInterrupted(id)
  }

  public func markResumed(_ id: SessionID) async throws {
    try await executionOwner.markResumed(id)
  }

  public func markErrored(_ id: SessionID, message: String) async throws {
    try await executionOwner.markErrored(id, message: message)
  }

  public func archive(_ id: SessionID, grace: Duration) async throws -> Date {
    try await executionOwner.archive(id, grace: grace)
  }

  public func unarchive(_ id: SessionID) async throws {
    try await executionOwner.unarchive(id)
  }

  public func restart(_ id: SessionID, executor: SessionExecutor?, note: String?, modelRoute: SessionModelRoute? = nil) async throws -> SessionRestart {
    try await executionOwner.restart(id, executor: executor, note: note, modelRoute: modelRoute)
  }

  public func registeredSubscriptions(_ id: SessionID) async throws -> (ids: Set<SubscriptionID>, handlers: Set<SubscriptionID>) {
    try await executionOwner.registeredSubscriptions(id)
  }

  public func providerCredential(_ provider: String) async throws -> ProviderCredential? {
    try await executionOwner.providerCredential(provider)
  }

  public func providerCredentialBinding(_ provider: String) async throws -> CredentialBinding? {
    try await executionOwner.providerCredentialBinding(provider)
  }

  public func inferenceBindingIdentity(audience: URL, session: SessionID) async throws -> String? {
    try await executionOwner.inferenceBindingIdentity(audience: audience, session: session)
  }

  public func inferenceToken(audience: URL, session: SessionID) async throws -> String {
    try await executionOwner.inferenceToken(audience: audience, session: session)
  }

  public func inferenceReadiness(audience: URL) async throws {
    try await executionOwner.inferenceReadiness(audience: audience)
  }

  public func modelGroupDocument() async throws -> Data? {
    try await executionOwner.modelGroupDocument()
  }

  public func modelDocument() async throws -> Data {
    try await executionOwner.modelDocument()
  }

  public func promptHome(_ id: SessionID) async throws -> SessionHome {
    try await executionOwner.promptHome(id)
  }

  public func handlesByPrincipal() async throws -> [String: String] {
    try await executionOwner.handlesByPrincipal()
  }

  public func deviceNames() async throws -> [String: String] {
    try await executionOwner.deviceNames()
  }

  public func mediaBytes(_ reference: MediaReference, group: GroupID) async throws -> Data {
    try await executionOwner.mediaBytes(reference, group: group)
  }

  public func recordMetric(_ metric: InferenceMetric) async {
    await executionOwner.recordMetric(metric)
  }
}
