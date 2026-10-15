#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import struct Credentials.CredentialBinding
import struct Credentials.CredentialResolver
import enum Credentials.ProviderCredential
import struct InferenceKit.AttemptTraceSink
import struct InferenceKit.InferenceMetric
import struct InferenceKit.InferenceMetricsSink
import SessionDomain
import struct SpaceContract.GroupID
import SpaceCore
import enum WuhuAI.InferenceError

public struct InProcessExecutionOwnerClient: ExecutionOwnerClient {
  private let attemptLog: AttemptLogConfig?
  public var tracesAttempts: Bool { attemptLog != nil }

  public func openAttemptTrace(_ id: UUID) async throws -> AttemptTraceSink {
    guard let attemptLog else { preconditionFailure("attempt tracing is not configured") }
    return try await attemptLog.traceClient.open(id)
  }

  private let space: Space
  private let sessions: InProcessSessionExecutionOwnerClient
  private let metrics: InferenceMetricsSink
  private let credentials: CredentialResolver
  private let readiness: (@Sendable (URL) async throws -> Void)?
  private let bindingIdentity: (@Sendable (URL, SessionID) async throws -> String)?
  private let token: (@Sendable (URL, SessionID) async throws -> String)?

  public init(
    space: Space, metrics: InferenceMetricsSink = .noop,
    credentials: CredentialResolver = .unavailable,
    inferenceToken: (@Sendable (URL, SessionID) async throws -> String)? = nil,
    inferenceReadiness: (@Sendable (URL) async throws -> Void)? = nil,
    inferenceBindingIdentity: (@Sendable (URL, SessionID) async throws -> String)? = nil,
    attemptLog: AttemptLogConfig? = nil,
  ) {
    self.attemptLog = attemptLog
    self.space = space
    sessions = InProcessSessionExecutionOwnerClient(sessions: space.sessions)
    self.metrics = metrics
    self.credentials = credentials
    readiness = inferenceReadiness
    token = inferenceToken
    bindingIdentity = inferenceBindingIdentity
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

  public func record(_ id: SessionID) async throws -> SessionRecord {
    try await space.sessions.record(id)
  }

  public func providerCredential(_ provider: String) async throws -> ProviderCredential? {
    try await providerCredentialBinding(provider)?.credential
  }

  public func providerCredentialBinding(_ provider: String) async throws -> CredentialBinding? {
    try await credentials.resolveBinding(provider)
  }

  public func inferenceBindingIdentity(audience: URL, session: SessionID) async throws -> String? {
    try await bindingIdentity?(audience, session)
  }

  public func inferenceToken(audience: URL, session: SessionID) async throws -> String {
    guard let token else {
      throw InferenceError.invalidInput(status: 422, body: "OIDC authentication is not configured on this server.")
    }
    return try await token(audience, session)
  }

  public func modelGroupDocument() async throws -> Data? {
    do { return try await space.fs(.shared).read("/model-groups.json").1 }
    catch SpaceError.notFound { return nil }
  }

  public func inferenceReadiness(audience: URL) async throws {
    guard token != nil else {
      throw InferenceError.invalidInput(status: 422, body: "OIDC authentication is not configured on this server.")
    }
    try await readiness?(audience)
  }

  public func modelDocument() async throws -> Data {
    let (_, data) = try await space.fs(.shared).read("/models.json")
    return data
  }

  public func promptHome(_ id: SessionID) async throws -> SessionHome {
    let rev = try await space.sessions.activatePromptRevision(id)
    return try await space.sessionHome(id, at: rev)
  }

  public func handlesByPrincipal() async throws -> [String: String] {
    try await space.handlesByPrincipal()
  }

  public func deviceNames() async throws -> [String: String] {
    try await space.deviceNames()
  }

  public func mediaBytes(_ reference: MediaReference, group: GroupID) async throws -> Data {
    try await space.mediaBytes(reference, group: group)
  }

  public func recordMetric(_ metric: InferenceMetric) async {
    await metrics.record(metric)
  }
}
