#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import struct Credentials.CredentialBinding
import enum Credentials.ProviderCredential
import struct InferenceKit.AttemptTraceSink
import struct InferenceKit.InferenceMetric
import enum SessionDomain.MediaReference
import struct SessionDomain.SessionID
import struct SpaceContract.GroupID
import protocol SpaceCore.SessionExecutionOwnerClient
import struct SpaceCore.SessionHome

public protocol ExecutionOwnerClient: SessionExecutionOwnerClient {
  var tracesAttempts: Bool { get }
  func openAttemptTrace(_ id: UUID) async throws -> AttemptTraceSink
  func providerCredential(_ provider: String) async throws -> ProviderCredential?
  func providerCredentialBinding(_ provider: String) async throws -> CredentialBinding?
  func inferenceToken(audience: URL, session: SessionID) async throws -> String
  func modelGroupDocument() async throws -> Data?
  func inferenceReadiness(audience: URL) async throws
  func inferenceBindingIdentity(audience: URL, session: SessionID) async throws -> String?
  func modelDocument() async throws -> Data
  func promptHome(_ id: SessionID) async throws -> SessionHome
  func handlesByPrincipal() async throws -> [String: String]
  func deviceNames() async throws -> [String: String]
  func mediaBytes(_ reference: MediaReference, group: GroupID) async throws -> Data
  func recordMetric(_ metric: InferenceMetric) async
}
