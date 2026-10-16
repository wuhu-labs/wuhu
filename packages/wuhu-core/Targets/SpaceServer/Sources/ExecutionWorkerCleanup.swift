#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import ImageRetention
import struct WorkerProtocol.WorkerProtocolError

struct ExecutionWorkerCleanup: Codable, Equatable, Sendable {
  let version: Int
  let space: String
  let generation: UUID
  let location: ExecutionWorkerSocketLocation
  let claim: ExecutionWorkerSocketDirectory.CleanupClaim

  var image: ImageReference? = nil

  func validate(space: String, generation: UUID, runtimeRoot: String) throws {
    guard version == 1, self.space == space, self.generation == generation, claim.isValid else { throw WorkerProtocolError(.invalidConfiguration, message: "Invalid execution worker cleanup record") }
    if let image {
      guard image.owner == "worker:" + space + ":" + image.id.uuidString else {
        throw WorkerProtocolError(.invalidConfiguration, message: "Invalid execution worker image cleanup reference")
      }
    }
    try location.validate(space: space, generation: generation, runtimeRoot: runtimeRoot)
  }

  func openClaim(runtimeRoot: String) async throws -> ExecutionWorkerSocketDirectory? {
    let sockets = try await ExecutionWorkerSocketDirectory.openIfPresent(location, space: space, generation: generation, runtimeRoot: runtimeRoot, cleanupClaim: claim)
    try await sockets?.verifyCleanupClaim(claim)
    return sockets
  }

  static func stage(store: ExecutionWorkerManifestStore, space: String, generation: UUID, location: ExecutionWorkerSocketLocation, sockets: ExecutionWorkerSocketDirectory, manifest: ExecutionWorkerManifest?, image: ImageReference? = nil) async throws -> Self {
    try await sockets.removeEndpoints()
    let record = Self(version: 1, space: space, generation: generation, location: location, claim: try await sockets.cleanupClaim(), image: image ?? manifest?.image)
    try await store.stageCleanup(record, manifest: manifest)
    return record
  }

  func finish(store: ExecutionWorkerManifestStore, sockets: ExecutionWorkerSocketDirectory?) async throws {
    try await sockets?.verifyCleanupClaim(claim)
    try await store.retireCleanupManifest(self)
    try await sockets?.cleanup()
    if let image { try await store.releaseImage(image) }
    try await store.removeCleanup(self)
  }
}
