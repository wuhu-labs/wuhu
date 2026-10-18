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
  private let sessions: InProcessMainClient
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
    sessions = InProcessMainClient(sessions: space.sessions)
    self.metrics = metrics
    self.credentials = credentials
    readiness = inferenceReadiness
    token = inferenceToken
    bindingIdentity = inferenceBindingIdentity
  }

  public func send(_ message: ToMain) async throws -> MainReply { try await sessions.send(message) }

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
