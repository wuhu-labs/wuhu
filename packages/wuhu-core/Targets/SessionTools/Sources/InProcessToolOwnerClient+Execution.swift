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
  public func send(_ message: ToMain) async throws -> MainReply { try await executionOwner.send(message) }

  public func scopeContext(_ id: SessionID, toolCallID: ToolCallID) async throws -> ScopeContext? { try await store.scopeContext(id, toolCallID: toolCallID) }

  public var tracesAttempts: Bool { executionOwner.tracesAttempts }

  public func openAttemptTrace(_ id: UUID) async throws -> AttemptTraceSink {
    try await executionOwner.openAttemptTrace(id)
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
