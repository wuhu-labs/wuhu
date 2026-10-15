#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import WorkerProtocol

struct ExecutionWorkerCredentialRotation {
  struct PreparedCredentials: Sendable {
    let manifest: ExecutionWorkerManifest
    let client: WorkerClient
  }

  static func prepare(
    manifest original: ExecutionWorkerManifest,
    hello: WorkerHello,
    persist: @Sendable (ExecutionWorkerManifest) async throws -> Void,
    connect: @Sendable (WorkerCredentials) throws -> WorkerClient,
    processBirth: @Sendable (Int32) throws -> String = processBirthIdentity,
  ) async throws -> PreparedCredentials {
    try original.validate()
    try original.verifyProcess(probe: processBirth)
    var pending = original
    if pending.credentials.successor == nil {
      pending.credentials.successor = UUID().uuidString + UUID().uuidString
      try await persist(pending)
    }
    guard let successor = pending.credentials.successor else { preconditionFailure() }
    let (client, credentials, authenticatedBy) = try await authenticate(pending, hello: hello, connect: connect)
    do {
      try await client.requireCapability("worker.credential-rotation.v1")
      guard await client.retainsReplies else { throw WorkerProtocolError(.missingCapability, message: "Execution worker credential recovery requires journal continuity") }
      try await client.stagePeerCredential(successor: successor, authenticatingWith: authenticatedBy)
      try await credentials.stage(successor: successor)
      try await client.reconnect()
      try await client.confirmPeerCredential(authenticatingWith: successor)
      try await credentials.confirm(successor: successor)
      try original.verifyProcess(probe: processBirth)
      pending.credentials = .init(current: successor)
      try await persist(pending)
      return PreparedCredentials(manifest: pending, client: client)
    } catch {
      await client.close()
      throw error
    }
  }

  private static func authenticate(
    _ manifest: ExecutionWorkerManifest,
    hello: WorkerHello,
    connect: @Sendable (WorkerCredentials) throws -> WorkerClient,
  ) async throws -> (WorkerClient, WorkerCredentials, String) {
    let candidates = [manifest.credentials.successor, manifest.credentials.current].compactMap { $0 }
    for token in candidates {
      let credentials = try WorkerCredentials(token: token)
      let client = try connect(credentials)
      do {
        _ = try await client.negotiate(hello)
        return (client, credentials, token)
      } catch {
        await client.close()
        guard let refusal = error as? WorkerProtocolError, refusal.code == .unauthorized else { throw error }
      }
    }
    throw WorkerProtocolError(.unauthorized, message: "Execution worker credential recovery was refused")
  }
}
