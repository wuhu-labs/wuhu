#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import enum JSONValue.JSONValue
import struct OperationProtocol.ChannelPayload
import enum OperationProtocol.ComputerKindSchemas
import struct OperationProtocol.KindDescriptor
import struct OperationProtocol.Offset
import struct OperationProtocol.OperationError
import OperationRuntime

public func fileOperationKinds(files: ComputerFileSystem = .local) -> [AnyOperationKind] {
  [AnyOperationKind(ReadKind(files: files)), AnyOperationKind(FindKind(files: files)), AnyOperationKind(GrepKind(files: files))]
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
  let root: String; let glob: String?; let pattern: String?; let dialect: String?; let maxLineBytes: Int?; let includeSymlinks: Bool; let entryLimit: Int?
  enum CodingKeys: String, CodingKey { case root, glob, pattern, dialect, maxLineBytes, includeSymlinks, entryLimit }
  init(from decoder: any Decoder) throws {
    try fields(decoder, allowed: ["root", "glob", "pattern", "dialect", "maxLineBytes", "includeSymlinks", "entryLimit"])
    let c = try decoder.container(keyedBy: CodingKeys.self)
    root = try c.decode(String.self, forKey: .root); try absolute(root)
    glob = try c.decodeIfPresent(String.self, forKey: .glob); pattern = try c.decodeIfPresent(String.self, forKey: .pattern)
    dialect = try c.decodeIfPresent(String.self, forKey: .dialect); maxLineBytes = try c.decodeIfPresent(Int.self, forKey: .maxLineBytes)
    includeSymlinks = try c.decodeIfPresent(Bool.self, forKey: .includeSymlinks) ?? false; entryLimit = try c.decodeIfPresent(Int.self, forKey: .entryLimit)
    guard entryLimit.map({ $0 > 0 }) ?? true else { throw OperationError(.invalidInput) }
    if let glob {
      guard pattern == nil, dialect == nil, maxLineBytes == nil, c.contains(.includeSymlinks) else { throw OperationError(.invalidInput) }
      guard !glob.isEmpty && glob.utf8.count <= 4096 else { throw OperationError(.invalidInput) }
    } else {
      guard dialect == "literal" else { throw OperationError(.unsupportedDialect, details: ["supported": ["literal"]]) }
      guard let pattern, !pattern.isEmpty, pattern.utf8.count <= 4096, let maxLineBytes, (1 ... 65536).contains(maxLineBytes) else { throw OperationError(.invalidInput) }
    }
  }
}

private struct FindKind: OperationKind {
  let files: ComputerFileSystem; let descriptor = ComputerKindSchemas.find
  func run(_ input: SearchInput, channels: OperationChannels, cancellation: OperationCancellation) async throws -> JSONValue {
    guard let glob = input.glob else { throw OperationError(.invalidInput) }
    let walk = try await files.walk(input.root, input.includeSymlinks)
    do {
      var scanned = 0; var matched = 0
      while true {
        try await cancellation.check()
        if let limit = input.entryLimit, scanned >= limit { try await cancellation.stop(reason: "entryLimit") }
        guard let entry = try await walk.next(check: { try await cancellation.check() }) else { break }
        scanned += 1
        let relative = entry.path.hasPrefix(input.root == "/" ? "/" : input.root + "/") ? String(entry.path.dropFirst(input.root == "/" ? 1 : input.root.count + 1)) : entry.path.split(separator: "/").last.map(String.init) ?? entry.path
        if globMatches(glob, relative) {
          try await channels.send(.init(records: [["path": .string(entry.path), "kind": .string(entry.kind)]]), to: "entries"); matched += 1
        }
      }
      await walk.close(); return searchResult(scanned: scanned, matched: matched, skipped: await walk.skipCounts())
    } catch { await walk.close(); throw error }
  }
}

private struct GrepKind: OperationKind {
  let files: ComputerFileSystem; let descriptor = ComputerKindSchemas.grep
  func run(_ input: SearchInput, channels: OperationChannels, cancellation: OperationCancellation) async throws -> JSONValue {
    guard let pattern = input.pattern, let maximum = input.maxLineBytes, input.dialect == "literal" else { throw OperationError(.invalidInput) }
    let walk = try await files.walk(input.root, false)
    do {
      var scanned = 0; var matched = 0; var skipped: [String: Int] = [:]
      while true {
        try await cancellation.check()
        if let limit = input.entryLimit, scanned >= limit { try await cancellation.stop(reason: "entryLimit") }
        guard let entry = try await walk.next(check: { try await cancellation.check() }) else { break }
        scanned += 1; guard entry.kind == "file" else { continue }
        do { try await scan(entry, pattern: pattern, maximum: maximum, channels: channels, cancellation: cancellation, matched: &matched) }
        catch let error as OperationError {
          let reason: String
          switch error.code {
          case .invalidInput: reason = "binary"
          case .recordTooLarge: reason = "oversized"
          case .fileChanged: reason = "changed"
          case .fileUnavailable: reason = "unreadable"
          default: throw error
          }
          skipped[reason, default: 0] += 1
        }
      }
      await walk.close()
      for (reason, count) in await walk.skipCounts() { skipped[reason, default: 0] += count }
      return searchResult(scanned: scanned, matched: matched, skipped: skipped)
    } catch { await walk.close(); throw error }
  }

  private func scan(_ entry: ComputerEntry, pattern: String, maximum: Int, channels: OperationChannels, cancellation: OperationCancellation, matched: inout Int) async throws {
    let path = entry.path
    let source = entry.file ?? ComputerFile(status: { try await self.files.status(path) }, read: { try await self.files.read(path, $0, $1) })
    let initial = try await source.status()
    guard initial.kind == "file" else { throw OperationError(.fileChanged) }
    var offset: UInt64 = 0; var line: UInt64 = 1; var buffer = Data()
    func emit() async throws {
      guard let text = String(data: buffer, encoding: .utf8) else { throw OperationError(.invalidInput) }
      if text.contains(pattern) { try await channels.send(.init(records: [["path": .string(path), "line": .string(String(line)), "text": .string(text)]]), to: "matches"); matched += 1 }
      buffer.removeAll(keepingCapacity: true); line += 1
    }
    while true {
      try await cancellation.check()
      let bytes = try await source.read(offset, 16384)
      guard bytes.count <= 16384 else { throw OperationError(.invalidResponse) }
      guard try await source.status() == initial else { throw OperationError(.fileChanged) }
      if bytes.contains(0) { throw OperationError(.invalidInput) }
      if bytes.isEmpty { if !buffer.isEmpty { try await emit() }; break }
      offset += UInt64(bytes.count)
      for byte in bytes {
        try Task.checkCancellation()
        if byte == 10 { try await emit() }
        else { guard buffer.count < maximum else { throw OperationError(.recordTooLarge) }; buffer.append(byte) }
      }
    }
  }
}

private func searchResult(scanned: Int, matched: Int, skipped: [String: Int]) -> JSONValue {
  ["scanned": .string(String(scanned)), "matched": .string(String(matched)), "skipped": .object(.init(uniqueKeysWithValues: skipped.map { ($0.key, .integer($0.value)) }))]
}

private struct FieldKey: CodingKey {
  let stringValue: String; var intValue: Int? { nil }
  init?(stringValue: String) { self.stringValue = stringValue }; init?(intValue: Int) { return nil }
}

private func fields(_ decoder: any Decoder, allowed: Set<String>) throws {
  guard try decoder.container(keyedBy: FieldKey.self).allKeys.allSatisfy({ allowed.contains($0.stringValue) }) else { throw OperationError(.invalidInput) }
}

private func absolute(_ path: String) throws {
  guard path.hasPrefix("/"), !path.utf8.contains(0), path.utf8.count <= 4096 else { throw OperationError(.invalidInput) }
}

private func verify(_ files: ComputerFileSystem, _ path: String, _ initial: ComputerFileStatus) async throws {
  guard try await files.status(path) == initial else { throw OperationError(.fileChanged) }
}

func globMatches(_ pattern: String, _ path: String) -> Bool {
  let p = Array(pattern.utf8); let s = Array(path.utf8)
  var previous = Array(repeating: false, count: s.count + 1); previous[0] = true
  var i = 0
  while i < p.count {
    let double = p[i] == 42 && i + 1 < p.count && p[i + 1] == 42
    var next = Array(repeating: false, count: s.count + 1)
    if p[i] == 42 {
      next[0] = previous[0]
      for j in 1 ... max(1, s.count) where j <= s.count { next[j] = previous[j] || (next[j - 1] && (double || s[j - 1] != 47)) }
      if double && i + 2 < p.count && p[i + 2] == 47 {
        var slash = previous
        for j in 1 ... max(1, s.count) where j <= s.count { slash[j] = slash[j] || (next[j - 1] && s[j - 1] == 47) }
        previous = slash; i += 3; continue
      }
    } else {
      for j in 1 ... max(1, s.count) where j <= s.count { next[j] = previous[j - 1] && (p[i] == s[j - 1] || (p[i] == 63 && s[j - 1] != 47)) }
    }
    previous = next; i += double ? 2 : 1
  }
  return previous[s.count]
}
