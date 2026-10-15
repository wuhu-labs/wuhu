#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import struct Credentials.CredentialBinding
import enum Credentials.ProviderCredential
import protocol ExecutionOwner.ExecutionOwnerClient
import struct InferenceKit.AttemptTraceSink
import struct InferenceKit.InferenceMetric
import enum JSONValue.JSONValue
import Logging
import struct SessionDomain.GenerationHead
import enum SessionDomain.MediaReference
import struct SessionDomain.ModelRouteFailure
import struct SessionDomain.ModelRouteTransition
import enum SessionDomain.QueueInput
import struct SessionDomain.ScopeContext
import enum SessionDomain.SessionExecutor
import struct SessionDomain.SessionID
import struct SessionDomain.SessionModelRoute
import struct SessionDomain.SubscriptionID
import struct SessionDomain.ToolCallID
import struct SessionDomain.ToolResultItem
import struct SessionDomain.Transcript
import enum SessionDomain.TranscriptItem
import struct SpaceContract.GroupID
import struct SpaceCore.CompactRequestClaim
import struct SpaceCore.QueueDrain
import enum SpaceCore.SessionCommand
import protocol SpaceCore.SessionExecutionOwnerClient
import struct SpaceCore.SessionHome
import struct SpaceCore.SessionHydration
import struct SpaceCore.SessionRecord
import struct SpaceCore.SessionRestart
import struct WorkerProtocol.WorkerCall
import class WorkerProtocol.WorkerClient
import struct WorkerProtocol.WorkerProtocolError

public struct RemoteExecutionOwner: ExecutionOwnerClient {
  public let tracesAttempts: Bool
  let rpc: OwnerRPC
  public init(client: WorkerClient, tracesAttempts: Bool) { rpc = OwnerRPC(client: client); self.tracesAttempts = tracesAttempts }
  public func record(_ id: SessionID) async throws -> SessionRecord {
    let result: RecordSnapshot = try await rpc.call("session.record", SessionIDRequest(id: id))
    return try result.record()
  }

  public func modelRoute(_ id: SessionID) async throws -> SessionModelRoute? {
    let result: SessionModelRoute? = try await rpc.call("session.model-route", SessionIDRequest(id: id))
    return result
  }

  public func establishModelRoute(_ id: SessionID, route: SessionModelRoute) async throws -> SessionModelRoute {
    let result: SessionModelRoute = try await rpc.call("session.establish-model-route", RouteRequest(id: id, route: route))
    return result
  }

  public func updateModelRouteFailure(_ id: SessionID, expectedEpoch: String, failure: ModelRouteFailure?) async throws {
    try await rpc.client.requireCapability(ExecutionWorkerBootstrap.routeTransitionsCapability)
    let _: Bool = try await rpc.call("session.update-model-route-failure", RouteFailureRequest(id: id, expectedEpoch: expectedEpoch, failure: failure))
  }

  public func hydrate(_ id: SessionID) async throws -> SessionHydration {
    let result: HydrationSnapshot = try await rpc.call("session.hydrate", SessionIDRequest(id: id))
    return try result.hydration()
  }

  public func enqueue(_ id: SessionID, input: QueueInput) async throws -> Int {
    let result: Int = try await rpc.call("session.enqueue", EnqueueRequest(id: id, input: input))
    return result
  }

  public func drainQueue(_ id: SessionID) async throws -> QueueDrain {
    let result: DrainSnapshot = try await rpc.call("session.drain-queue", SessionIDRequest(id: id))
    return result.drain
  }

  public func discardPendingCacheWarming(_ id: SessionID) async throws -> Transcript {
    let result: TranscriptSnapshot = try await rpc.call("session.discard-pending-cache-warming", SessionIDRequest(id: id))
    return result.value
  }

  public func append(_ id: SessionID, items: [TranscriptItem], transcript: Transcript, completingCompactRequest: CompactRequestClaim?) async throws -> Void {
    let _: Bool = try await rpc.call("session.append", AppendRequest(id: id, items: items, transcript: .init(transcript), claim: try remoteHandle(completingCompactRequest)))
  }

  public func scopeContext(_ id: SessionID, toolCallID: ToolCallID) async throws -> ScopeContext? {
    let result: ScopeContext? = try await rpc.call("session.scope-context", ScopeRequest(id: id, toolCallID: toolCallID))
    return result
  }

  public func queueHead(_ id: SessionID) async throws -> Int {
    let result: Int = try await rpc.call("session.queue-head", SessionIDRequest(id: id))
    return result
  }

  public func pendingCommand(_ id: SessionID) async throws -> SessionCommand? {
    let result: CommandSnapshot? = try await rpc.call("session.pending-command", SessionIDRequest(id: id))
    return try result?.command()
  }

  public func claimCompactRequest(_ id: SessionID, generation: Int) async throws -> CompactRequestClaim? {
    let result: CompactClaimSnapshot? = try await rpc.call("session.claim-compact-request", ClaimRequest(id: id, generation: generation))
    return try result?.claim()
  }

  public func writePortableHandoff(_ id: SessionID, expectedGeneration: Int, source: Transcript, transcript: Transcript, transition: ModelRouteTransition?) async throws -> Transcript {
    if transition != nil { try await rpc.client.requireCapability(ExecutionWorkerBootstrap.routeTransitionsCapability) }
    let result: TranscriptSnapshot = try await rpc.call("session.write-portable-handoff", HandoffRequest(id: id, expectedGeneration: expectedGeneration, source: .init(source), transcript: .init(transcript), transition: transition.map(RouteTransitionSnapshot.init)))
    return result.value
  }

  public func writeCompaction(_ id: SessionID, closing: ToolResultItem?, head: GenerationHead, kept: Range<Int>?, completingCompactRequest: CompactRequestClaim?, transition: ModelRouteTransition?) async throws -> Transcript {
    if transition != nil { try await rpc.client.requireCapability(ExecutionWorkerBootstrap.routeTransitionsCapability) }
    let result: TranscriptSnapshot = try await rpc.call("session.write-compaction", CompactionRequest(id: id, closing: closing, head: head, kept: kept, claim: try remoteHandle(completingCompactRequest), transition: transition.map(RouteTransitionSnapshot.init)))
    return result.value
  }

  public func markInterrupted(_ id: SessionID) async throws -> Void {
    let _: Bool = try await rpc.call("session.mark-interrupted", SessionIDRequest(id: id))
  }

  public func markResumed(_ id: SessionID) async throws -> Void {
    let _: Bool = try await rpc.call("session.mark-resumed", SessionIDRequest(id: id))
  }

  public func markErrored(_ id: SessionID, message: String) async throws -> Void {
    let _: Bool = try await rpc.call("session.mark-errored", ErrorRequest(id: id, message: message))
  }

  public func archive(_ id: SessionID, grace: Duration) async throws -> Date {
    let result: Date = try await rpc.call("session.archive", ArchiveRequest(id: id, grace: .init(grace)))
    return result
  }

  public func unarchive(_ id: SessionID) async throws -> Void {
    let _: Bool = try await rpc.call("session.unarchive", SessionIDRequest(id: id))
  }

  public func restart(_ id: SessionID, executor: SessionExecutor?, note: String?, modelRoute: SessionModelRoute?) async throws -> SessionRestart {
    let result: RestartSnapshot = try await rpc.call("session.restart", RestartRequest(id: id, executor: executor.map(ExecutorSnapshot.init), note: note, modelRoute: modelRoute))
    return try result.restart()
  }

  public func registeredSubscriptions(_ id: SessionID) async throws -> (ids: Set<SubscriptionID>, handlers: Set<SubscriptionID>) {
    let result: SubscriptionsSnapshot = try await rpc.call("session.registered-subscriptions", SessionIDRequest(id: id))
    return (result.ids, result.handlers)
  }

  public func providerCredential(_ provider: String) async throws -> ProviderCredential? {
    let result: CredentialSnapshot? = try await rpc.call("inference.provider-credential", ProviderRequest(provider: provider))
    return try result?.credential()
  }

  public func providerCredentialBinding(_ provider: String) async throws -> CredentialBinding? {
    let result: CredentialBindingSnapshot? = try await rpc.call("inference.provider-credential-binding", ProviderRequest(provider: provider))
    return try result?.binding()
  }

  public func inferenceToken(audience: URL, session: SessionID) async throws -> String {
    let result: String = try await rpc.call("inference.inference-token", TokenRequest(audience: audience, session: session))
    return result
  }

  public func inferenceReadiness(audience: URL) async throws -> Void {
    let _: Bool = try await rpc.call("inference.inference-readiness", AudienceRequest(audience: audience))
  }

  public func inferenceBindingIdentity(audience: URL, session: SessionID) async throws -> String? {
    let result: String? = try await rpc.call("inference.inference-binding-identity", TokenRequest(audience: audience, session: session))
    return result
  }

  public func modelGroupDocument() async throws -> Data? {
    let result: Data? = try await rpc.call("inference.model-group-document", EmptyRequest())
    return result
  }

  public func modelDocument() async throws -> Data {
    let result: Data = try await rpc.call("inference.model-document", EmptyRequest())
    return result
  }

  public func promptHome(_ id: SessionID) async throws -> SessionHome {
    let result: HomeSnapshot = try await rpc.call("inference.prompt-home", SessionIDRequest(id: id))
    return result.value
  }

  public func handlesByPrincipal() async throws -> [String: String] {
    let result: [String: String] = try await rpc.call("inference.handles-by-principal", EmptyRequest())
    return result
  }

  public func deviceNames() async throws -> [String: String] {
    let result: [String: String] = try await rpc.call("inference.device-names", EmptyRequest())
    return result
  }

  public func mediaBytes(_ reference: MediaReference, group: GroupID) async throws -> Data {
    let result: Data = try await rpc.call("inference.media-bytes", MediaRequest(reference: .init(reference), group: group))
    return result
  }

  public func openAttemptTrace(_ id: UUID) async throws -> AttemptTraceSink {
    let _: Bool = try await rpc.call("inference.trace-open", TraceRequest(id: id))
    return AttemptTraceSink { [rpc] data in
      await Task {
        do { let _: Bool = try await rpc.call("inference.trace-append", TraceAppendRequest(id: id, data: data)) }
        catch { Logger(label: "wuhu.worker").error("Attempt trace publication failed") }
      }.value
    }
  }

  public func closeAttemptTrace(_ id: UUID) async {
    await Task { [rpc] in
      do { let _: Bool = try await rpc.call("inference.trace-close", TraceRequest(id: id)) }
      catch { Logger(label: "wuhu.worker").error("Attempt trace close failed") }
    }.value
  }

  public func recordMetric(_ metric: InferenceMetric) async {
    await Task { [rpc] in
      do { let _: Bool = try await rpc.call("inference.metric", MetricSnapshot(metric)) }
      catch { Logger(label: "wuhu.worker").error("Inference metric publication failed") }
    }.value
  }
}
