#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import struct Credentials.CredentialBinding
import struct Credentials.CredentialResolver
import enum Credentials.ProviderCredential
import ExecutionOwner
import struct InferenceKit.AttemptTraceSink
import struct InferenceKit.InferenceMetric
import struct InferenceKit.InferenceMetricsSink
import SessionDomain
import struct SpaceContract.GroupID
import SpaceCore
import enum WuhuAI.InferenceError

extension Hub {
  nonisolated public var tracesAttempts: Bool { attemptLog != nil }

  nonisolated public func openAttemptTrace(_ id: UUID) async throws -> AttemptTraceSink {
    guard let attemptLog else { preconditionFailure("attempt tracing is not configured") }
    return try await attemptLog.traceClient.open(id)
  }

  nonisolated public func providerCredentialBinding(_ provider: String) async throws -> CredentialBinding? {
    try await credentials.resolveBinding(provider)
  }

  nonisolated public func inferenceBindingIdentity(audience: URL, session: SessionID) async throws -> String? {
    try await bindingIdentity?(audience, session)
  }

  nonisolated public func inferenceToken(audience: URL, session: SessionID) async throws -> String {
    guard let token else {
      throw InferenceError.invalidInput(status: 422, body: "OIDC authentication is not configured on this server.")
    }
    return try await token(audience, session)
  }

  nonisolated public func inferenceReadiness(audience: URL) async throws {
    guard token != nil else {
      throw InferenceError.invalidInput(status: 422, body: "OIDC authentication is not configured on this server.")
    }
    try await readiness?(audience)
  }

  nonisolated public func promptHome(_ id: SessionID) async throws -> SessionHome {
    let rev = try await space.sessions.activatePromptRevision(id)
    return try await space.sessionHome(id, at: rev)
  }

  nonisolated public func mediaBytes(_ reference: MediaReference, group: GroupID) async throws -> Data {
    try await space.mediaBytes(reference, group: group)
  }

  nonisolated public func recordMetric(_ metric: InferenceMetric) async {
    await metrics.record(metric)
  }
}
