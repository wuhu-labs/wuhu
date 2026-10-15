#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import Crypto
import enum JSONValue.JSONValue
import enum OperationProtocol.ComputerKindSchemas
import struct OperationProtocol.KindDescriptor
import struct OperationProtocol.Offset
import struct OperationProtocol.OperationClock
import struct OperationProtocol.OperationError
import OperationRuntime

func metadataOperationKinds(files: ComputerFileOperations) -> [AnyOperationKind] {
  [ComputerKindSchemas.stat, ComputerKindSchemas.list, ComputerKindSchemas.write, ComputerKindSchemas.mkdir, ComputerKindSchemas.remove, ComputerKindSchemas.move].map { AnyOperationKind(MetadataKind(descriptor: $0, files: files)) }
}

private struct MetadataInput: Decodable, Sendable {
  let path: String?; let from: String?; let to: String?; let ifMatch: String?; let bytes: Offset?; let digest: String?
  enum CodingKeys: String, CodingKey { case path, from, to, ifMatch, bytes, digest }
  init(from decoder: any Decoder) throws {
    try fields(decoder, allowed: ["path", "from", "to", "ifMatch", "bytes", "digest"])
    let c = try decoder.container(keyedBy: CodingKeys.self)
    path = try c.decodeIfPresent(String.self, forKey: .path); from = try c.decodeIfPresent(String.self, forKey: .from); to = try c.decodeIfPresent(String.self, forKey: .to)
    ifMatch = try c.decodeIfPresent(String.self, forKey: .ifMatch); bytes = try c.decodeIfPresent(Offset.self, forKey: .bytes); digest = try c.decodeIfPresent(String.self, forKey: .digest)
    for path in [path, from, to].compactMap({ $0 }) { try absolute(path) }
  }
}

private struct MetadataKind: OperationKind {
  let descriptor: KindDescriptor
  let files: ComputerFileOperations
  func validate(_ input: MetadataInput) throws {
    if descriptor.name == "move.v1" {
      guard input.from != nil, input.to != nil, input.path == nil, input.ifMatch == nil, input.bytes == nil, input.digest == nil else { throw OperationError(.invalidInput) }
    } else {
      guard input.path != nil, input.from == nil, input.to == nil else { throw OperationError(.invalidInput) }
      if descriptor.name == "write.v1" {
        guard let digest = input.digest, digest.utf8.count == 64, digest.utf8.allSatisfy({ (48 ... 57).contains($0) || (97 ... 102).contains($0) }), input.bytes != nil else { throw OperationError(.invalidInput) }
      } else {
        guard input.bytes == nil, input.digest == nil, input.ifMatch == nil || descriptor.name == "remove.v1" else { throw OperationError(.invalidInput) }
      }
    }
  }

  func run(_ input: MetadataInput, channels: OperationChannels, cancellation: OperationCancellation) async throws -> JSONValue {
    try await withThrowingTaskGroup(of: JSONValue.self) { group in
      defer { group.cancelAll() }
      group.addTask { try await self.perform(input, channels: channels, cancellation: cancellation) }
      group.addTask {
        while true { try await cancellation.check(); try await OperationClock.continuous.sleep(.milliseconds(10)) }
      }
      return try await group.next()!
    }
  }

  private func perform(_ input: MetadataInput, channels: OperationChannels, cancellation: OperationCancellation) async throws -> JSONValue {
    try await cancellation.check()
    switch descriptor.name {
    case "stat.v1": return try json(await files.stat(input.path!))
    case "list.v1":
      let directory = try await files.list(input.path!)
      do {
        var count = 0
        while true {
          try await cancellation.check()
          guard let entry = try await directory.next() else { break }
          try await channels.send(.init(records: [try json(entry)]), to: "entries"); count += 1
        }
        await directory.close(); return ["count": .string(String(count))]
      } catch { await directory.close(); throw error }
    case "write.v1":
      let writer = try await files.write(input.path!, input.ifMatch)
      do {
        var hash = SHA256(); var count: UInt64 = 0
        while let chunk = try await channels.read("data", upTo: 65536) {
          try await cancellation.check()
          guard let data = chunk.data, UInt64(data.count) <= input.bytes!.rawValue - count else { throw OperationError(.invalidInput) }
          hash.update(data: data); count += UInt64(data.count); try await writer.append(data)
        }
        guard count == input.bytes!.rawValue, hash.finalize().map({ String(format: "%02x", $0) }).joined() == input.digest else { throw OperationError(.invalidInput, message: "Write length or digest mismatch") }
        try await writer.prepare()
        try await cancellation.check()
        let version = try await writer.commit()
        let result: JSONValue = ["version": .string(version)]
        try await channels.publish(.init(.completed, result: result))
        await writer.close(); return result
      } catch { await writer.close(); throw error }
    case "mkdir.v1": try await files.mkdir(input.path!)
    case "remove.v1": try await files.remove(input.path!, input.ifMatch)
    case "move.v1": try await files.move(input.from!, input.to!)
    default: throw OperationError(.unknownKind)
    }
    return .object([:])
  }
}

private func json(_ value: some Encodable) throws -> JSONValue { try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(value)) }
