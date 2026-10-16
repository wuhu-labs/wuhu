#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import ImageRetention
import struct WorkerProtocol.WorkerProtocolError

struct ExecutionWorkerPreparation: Codable, Equatable, Sendable {
  let version: Int
  let space: String
  let generation: UUID
  let location: ExecutionWorkerSocketLocation
  let image: ImageReference

  func validate(space: String, generation: UUID, runtimeRoot: String) throws {
    guard version == 1, self.space == space, self.generation == generation,
          image.processID == nil, image.birth == nil, image.owner == "worker:" + space + ":" + image.id.uuidString
    else {
      throw WorkerProtocolError(.invalidConfiguration, message: "Invalid worker image preparation")
    }
    try location.validate(space: space, generation: generation, runtimeRoot: runtimeRoot)
  }
}
