#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import enum JSONValue.JSONValue
import struct WorkerProtocol.WorkerProtocolError

public struct ParentExecutionIdentity: Sendable {
  let value: ParentExecCheckpoint.Identity

  public init(space: String, generation: UUID, incarnation: UUID, processID: Int32, birth: String) {
    value = .init(space: space, generation: generation, incarnation: incarnation, processID: processID, birth: birth)
  }
}

struct ParentExecCheckpoint: Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
  struct Identity: Codable, Equatable, Sendable {
    let space: String
    let generation: UUID
    let incarnation: UUID
    let processID: Int32
    let birth: String

    func validate() throws {
      guard !space.isEmpty, space.utf8.count <= 1024, processID > 0,
            (16 ... 128).contains(birth.utf8.count)
      else { throw ParentExecCheckpoint.invalid() }
    }
  }

  private struct Envelope: Codable {
    let version: Int
    let identity: Identity
    let execution: ParentExecutionCheckpoint
  }

  static let maximumBytes = 128 << 20
  let identity: Identity
  let execution: ParentExecutionCheckpoint
  var description: String { "ParentExecCheckpoint(<redacted>)" }
  var debugDescription: String { description }
  var customMirror: Mirror { Mirror(self, children: [:]) }

  func encode() throws -> Data {
    try identity.validate()
    try execution.validate()
    let data = try JSONEncoder().encode(Envelope(version: 1, identity: identity, execution: execution))
    try Self.requireSize(data)
    return data
  }

  static func decode(_ data: Data, expecting identity: Identity) throws -> Self {
    try requireSize(data)
    do {
      try identity.validate()
      try ParentCheckpointJSON.validateKeys(data)
      let envelope = try JSONDecoder().decode(Envelope.self, from: data)
      guard envelope.version == 1, envelope.identity == identity else { throw invalid() }
      let normalized = try JSONEncoder().encode(envelope)
      let original = try JSONDecoder().decode(JSONValue.self, from: data)
      let retained = try JSONDecoder().decode(JSONValue.self, from: normalized)
      try requireRetainedFields(original, retained)
      try envelope.execution.validate()
      return Self(identity: envelope.identity, execution: envelope.execution)
    } catch {
      throw invalid()
    }
  }

  private static func requireSize(_ data: Data) throws {
    guard data.count <= maximumBytes else {
      throw WorkerProtocolError(.capacityExceeded, message: "Parent exec checkpoint exceeds its byte limit")
    }
  }

  // Codable normally discards unknown keys. Comparing the decoded/re-encoded shape
  // fences every structural layer while leaving opaque JSON payloads intact.
  private static func requireRetainedFields(_ input: JSONValue, _ retained: JSONValue) throws {
    switch (input, retained) {
    case let (.object(input), .object(retained)):
      guard Set(input.keys) == Set(retained.keys) else { throw invalid() }
      for (key, value) in input { try requireRetainedFields(value, retained[key]!) }
    case let (.array(input), .array(retained)):
      guard input.count == retained.count else { throw invalid() }
      for (value, kept) in zip(input, retained) { try requireRetainedFields(value, kept) }
    case (.object, _), (.array, _), (_, .object), (_, .array): throw invalid()
    default: break
    }
  }

  private static func invalid() -> WorkerProtocolError {
    .init(.invalidConfiguration, message: "Invalid parent exec checkpoint")
  }
}
