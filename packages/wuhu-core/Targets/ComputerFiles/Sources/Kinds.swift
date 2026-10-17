#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import FileSearch
import enum JSONValue.JSONValue
import struct OperationProtocol.ChannelPayload
import enum OperationProtocol.ComputerKindSchemas
import struct OperationProtocol.KindDescriptor
import struct OperationProtocol.Offset
import struct OperationProtocol.OperationError
import OperationRuntime

/// `searchClock` times a search's ``FileSearch/SearchLimits/deadline``.
public func fileOperationKinds(files: ComputerFileSystem = .local, searchClock: any Clock<Duration> = ContinuousClock()) -> [AnyOperationKind] {
  [AnyOperationKind(ReadKind(files: files)), AnyOperationKind(SearchKind(files: files, clock: searchClock))] + metadataOperationKinds(files: files.operations)
}

private struct ReadInput: Decodable, Sendable {
  let path: String; let offset: Offset; let length: Offset?; let ifMatch: String?
  enum CodingKeys: String, CodingKey { case path, offset, length, ifMatch }
  init(from decoder: any Decoder) throws {
    try fields(decoder, allowed: ["path", "offset", "length", "ifMatch"])
    let c = try decoder.container(keyedBy: CodingKeys.self)
    path = try c.decode(String.self, forKey: .path); offset = try c.decodeIfPresent(Offset.self, forKey: .offset) ?? .zero
    length = try c.decodeIfPresent(Offset.self, forKey: .length); ifMatch = try c.decodeIfPresent(String.self, forKey: .ifMatch)
    try absolute(path)
    guard offset.rawValue <= UInt64(Int64.max), length.map({ $0.rawValue <= UInt64(Int64.max) - offset.rawValue }) ?? true else { throw OperationError(.invalidInput) }
  }
}

private struct ReadKind: OperationKind {
  let files: ComputerFileSystem
  let descriptor = ComputerKindSchemas.read
  func run(_ input: ReadInput, channels: OperationChannels, cancellation: OperationCancellation) async throws -> JSONValue {
    let initial = try await files.status(input.path)
    guard initial.kind == "file" else { throw OperationError(.fileUnavailable) }
    guard input.ifMatch == nil || input.ifMatch == initial.version else { throw OperationError(.fileChanged) }
    var count: UInt64 = 0; var eof = input.offset.rawValue >= initial.size
    while !eof && (input.length == nil || count < input.length!.rawValue) {
      try await cancellation.check()
      let maximum = Int(min(65536, input.length.map { $0.rawValue - count } ?? 65536))
      let bytes = try await files.read(input.path, input.offset.rawValue + count, maximum)
      guard bytes.count <= maximum else { throw OperationError(.invalidResponse) }
      try await verify(files, input.path, initial)
      try await cancellation.check()
      if bytes.isEmpty { eof = true; break }
      try await channels.send(.init(data: bytes), to: "data")
      count += UInt64(bytes.count); eof = input.offset.rawValue + count >= initial.size
    }
    try await verify(files, input.path, initial)
    return ["version": .string(initial.version), "bytes": .string(String(count)), "reachedEOF": .bool(eof)]
  }
}

private struct SearchInput: Decodable, Sendable {
  let query: SearchQuery
  init(from decoder: any Decoder) throws {
    try fields(decoder, allowed: ["mode", "pattern", "root", "scope", "hidden", "noIgnore", "limit", "step"])
    query = try SearchQuery(from: decoder)
  }
}

/// A search's own error, typed for the wire: `details.search` is its code.
private func operationError(_ error: SearchError) -> OperationError {
  let code: OperationError.Code = switch error.code {
  case .notFound: .fileUnavailable
  case .timeout: .kindFailed
  default: .invalidInput
  }
  return OperationError(code, message: error.message, details: ["search": .string(error.code.rawValue)])
}

/// One page of a find or grep, as the result: the engine bounds it, so it
/// fits ``OperationProtocol/OperationLimits/resultBytes``.
private struct SearchKind: OperationKind {
  let files: ComputerFileSystem
  let clock: any Clock<Duration>
  let descriptor = ComputerKindSchemas.search
  func validate(_ input: SearchInput) throws {
    do { try input.query.validate() } catch { throw operationError(error) }
  }

  func run(_ input: SearchInput, channels: OperationChannels, cancellation: OperationCancellation) async throws -> SearchPage {
    let source = files.search(input.query.root)
    do {
      return try await withThrowingTaskGroup(of: SearchPage?.self) { group in
        defer { group.cancelAll() }
        group.addTask { [clock] in try await input.query.run(in: source, clock: clock) }
        // A stop or lease expiry is not task cancellation; poll for it.
        group.addTask { [clock] in
          while true {
            try await cancellation.check()
            try await clock.sleep(for: .milliseconds(10))
          }
        }
        return try await group.next()!!
      }
    } catch let error as SearchError {
      throw operationError(error)
    } catch let error as SearchUnreadable {
      throw OperationError(.fileUnavailable, message: "\(input.query.root): \(error.reason)")
    }
  }
}

private struct FieldKey: CodingKey {
  let stringValue: String; var intValue: Int? { nil }
  init?(stringValue: String) { self.stringValue = stringValue }; init?(intValue: Int) { return nil }
}

func fields(_ decoder: any Decoder, allowed: Set<String>) throws {
  guard try decoder.container(keyedBy: FieldKey.self).allKeys.allSatisfy({ allowed.contains($0.stringValue) }) else { throw OperationError(.invalidInput) }
}

func absolute(_ path: String) throws {
  guard path.hasPrefix("/"), !path.utf8.contains(0), path.utf8.count <= 4096 else { throw OperationError(.invalidInput) }
}

private func verify(_ files: ComputerFileSystem, _ path: String, _ initial: ComputerFileStatus) async throws {
  guard try await files.status(path) == initial else { throw OperationError(.fileChanged) }
}
