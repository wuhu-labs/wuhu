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
import struct OperationProtocol.OperationError
import struct OperationProtocol.OperationLimits
import OperationRuntime

func metadataOperationKinds(files: ComputerFileOperations) -> [AnyOperationKind] {
  [ComputerKindSchemas.stat, ComputerKindSchemas.list, ComputerKindSchemas.write, ComputerKindSchemas.mkdir, ComputerKindSchemas.remove, ComputerKindSchemas.move].map { AnyOperationKind(MetadataKind(descriptor: $0, files: files)) }
    + [AnyOperationKind(StagedWriteKind(files: files))]
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

  /// A write knows its length at start, so `data` is admitted for what it moves, not the descriptor's ceiling.
  func start(_ input: MetadataInput, limits: OperationLimits) async throws -> OperationStart<JSONValue> {
    let windows = descriptor.name == "write.v1" ? ["data": Int(min(input.bytes!.rawValue, UInt64(limits.filePieceBytes)))] : [:]
    return OperationStart(windows: windows) { channels, cancellation in try await run(input, channels: channels, cancellation: cancellation) }
  }

  private func run(_ input: MetadataInput, channels: OperationChannels, cancellation: OperationCancellation) async throws -> JSONValue {
    try await cancellation.unlessStopped { try await self.perform(input, channels: channels, cancellation: cancellation) }
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
      return try await stream("data", into: files.write(input.path!, input.ifMatch.map(WriteCondition.version) ?? .any), channels: channels, cancellation: cancellation, limit: input.bytes!.rawValue) { count, digest in
        guard count == input.bytes!.rawValue, digest == input.digest else { throw OperationError(.invalidInput, message: "Write length or digest mismatch") }
      }
    case "mkdir.v1": try await files.mkdir(input.path!)
    case "remove.v1": try await files.remove(input.path!, input.ifMatch)
    case "move.v1": try await files.move(input.from!, input.to!)
    default: throw OperationError(.unknownKind)
    }
    return .object([:])
  }
}

/// Appends `channel` to `writer` until it ends, hands its length and sha256 to `verify`, then lands the write and publishes its
/// version before the writer closes; any failure closes it unlanded.
private func stream(_ channel: String, into writer: ComputerWriter, channels: OperationChannels, cancellation: OperationCancellation, limit: UInt64 = .max, verify: (UInt64, String) async throws -> Void) async throws -> JSONValue {
  do {
    var hash = SHA256(); var count: UInt64 = 0
    while let chunk = try await channels.read(channel, upTo: OperationLimits.maxFilePieceBytes) {
      guard let data = chunk.data, UInt64(data.count) <= limit - count else { throw OperationError(.invalidInput) }
      hash.update(data: data); count += UInt64(data.count); try await writer.append(data)
    }
    try await verify(count, hash.finalize().map { String(format: "%02x", $0) }.joined())
    try await writer.prepare()
    try await cancellation.check()
    let version = try await writer.commit()
    let result: JSONValue = ["version": .string(version)]
    try await channels.publish(.init(.completed, result: result))
    await writer.close(); return result
  } catch { await writer.close(); throw error }
}

private struct StagedWriteInput: Decodable, Sendable {
  let path: String; let replace: Bool; let length: Offset?
  enum CodingKeys: String, CodingKey { case path, replace, length }
  init(from decoder: any Decoder) throws {
    try fields(decoder, allowed: ["path", "replace", "length"])
    let c = try decoder.container(keyedBy: CodingKeys.self)
    path = try c.decode(String.self, forKey: .path); replace = try c.decode(Bool.self, forKey: .replace)
    length = try c.decodeIfPresent(Offset.self, forKey: .length)
    try absolute(path)
  }
}

private struct StagedCommit: Decodable { let bytes: Offset; let sha256: String }

private struct StagedWriteKind: OperationKind {
  let files: ComputerFileOperations
  let descriptor = ComputerKindSchemas.stagedWrite
  /// A copy that pins its source knows how much it will send; one that does not is admitted for a piece, never the descriptor
  /// ceiling.
  func start(_ input: StagedWriteInput, limits: OperationLimits) async throws -> OperationStart<JSONValue> {
    let piece = min(descriptor.inputChannels[0].windowBytes, limits.filePieceBytes)
    let windows = ["data": Int(min(input.length?.rawValue ?? UInt64(piece), UInt64(piece)))]
    return OperationStart(windows: windows) { channels, cancellation in try await run(input, channels: channels, cancellation: cancellation) }
  }

  private func run(_ input: StagedWriteInput, channels: OperationChannels, cancellation: OperationCancellation) async throws -> JSONValue {
    try await cancellation.unlessStopped {
      try await stream("data", into: files.write(input.path, input.replace ? .any : .absent), channels: channels, cancellation: cancellation) { count, digest in
        guard let record = try await channels.read("commit", upTo: 1024)?.records?.first else { throw OperationError(.invalidInput, message: "No commit record") }
        let commit = try JSONDecoder().decode(StagedCommit.self, from: Data(record.jsonString().utf8))
        guard commit.bytes.rawValue == count, commit.sha256 == digest else { throw OperationError(.invalidInput, message: "Write length or digest mismatch") }
      }
    }
  }
}

private func json(_ value: some Encodable) throws -> JSONValue { try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(value)) }
