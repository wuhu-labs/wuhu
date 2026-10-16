#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import CProcessIdentity
import struct ImageRetention.ImageReference
import struct WorkerProtocol.WorkerProtocolError

struct ExecutionWorkerManifest: Codable, Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
  var description: String { "ExecutionWorkerManifest(redacted)" }
  var debugDescription: String { description }
  struct Credentials: Codable, Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    var description: String { "ExecutionWorkerCredentials(redacted)" }
    var debugDescription: String { description }
    let current: String
    var successor: String?
  }

  let version: Int
  let space: String
  let generation: UUID
  let incarnation: UUID
  let processID: Int32
  let birth: String
  var credentials: Credentials
  var sockets: ExecutionWorkerSocketLocation? = nil

  var image: ImageReference? = nil

  func validate() throws {
    if let image {
      guard image.id == incarnation, image.processID == processID, image.birth == birth, image.owner == "worker:" + space + ":" + incarnation.uuidString else {
        throw WorkerProtocolError(.invalidConfiguration, message: "Invalid execution worker image reference")
      }
    }
    let tokens = [credentials.current] + (credentials.successor.map { [$0] } ?? [])
    guard (version == 1 && sockets == nil || version == 2 && sockets != nil), !space.isEmpty, processID > 0,
          birth.utf8.count >= 16, birth.utf8.count <= 128,
          tokens.allSatisfy({ $0.utf8.count >= 64 && $0.utf8.count <= 128 && $0.utf8.allSatisfy { $0 > 32 && $0 < 127 } }),
          credentials.successor != credentials.current
    else { throw WorkerProtocolError(.invalidConfiguration, message: "Invalid execution worker manifest") }
  }

  func validate(directory: String, space expectedSpace: String, runtimeRoot: String = ExecutionWorkerSocketLocation.runtimeRoot) throws {
    try validate()
    guard space == expectedSpace, directory.hasPrefix("/"), sockets != nil || (directory + "/worker.sock").utf8.count < 104 else {
      throw WorkerProtocolError(.invalidConfiguration, message: "Invalid execution worker manifest location")
    }
    try sockets?.validate(space: space, generation: generation, runtimeRoot: runtimeRoot)
  }

  func workerSocket(directory: String) -> String { sockets?.worker ?? directory + "/worker.sock" }

  func verifyProcess(probe: @Sendable (Int32) throws -> String = processBirthIdentity) throws {
    guard try probe(processID) == birth else { throw WorkerProtocolError(.unauthorized, message: "Execution worker process identity changed") }
  }
}

func processBirthIdentity(_ processID: Int32) throws -> String {
  var output = [CChar](repeating: 0, count: 256)
  guard process_birth_identity(processID, &output, output.count) == 0 else {
    throw WorkerProtocolError(.unavailable, message: "Cannot establish execution worker process identity")
  }
  return String(decoding: output.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
}
