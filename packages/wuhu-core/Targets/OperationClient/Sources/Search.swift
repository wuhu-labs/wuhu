#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import enum JSONValue.JSONValue
import MachineContract
import struct OperationProtocol.OperationError

private struct SearchCursor: Codable {
  let machine: String
  let query: SearchQuery
  let entry: Int
  let line: Int
}

public extension OperationClient {
  func search(machine: String, query: SearchQuery) async throws -> SearchResult {
    let canonical: SearchQuery
    let step: String?; let limit: Int; let entryLimit: Int; let channel: String; let kind: String
    var input: [String: JSONValue]
    switch query {
    case let .find(glob, path, matches, entries, cursor):
      canonical = .find(glob: glob, path: path, matchLimit: nil, entryLimit: nil, step: nil)
      step = cursor; limit = matches ?? 50; entryLimit = entries ?? 1000; channel = "entries"; kind = "find.v1"
      input = ["root": .string(path ?? "/"), "glob": .string(glob), "includeSymlinks": true]
    case let .grep(pattern, path, matches, entries, cursor):
      canonical = .grep(pattern: pattern, path: path, matchLimit: nil, entryLimit: nil, step: nil)
      step = cursor; limit = matches ?? 50; entryLimit = entries ?? 1000; channel = "matches"; kind = "grep.v1"
      input = ["root": .string(path ?? "/"), "pattern": .string(pattern), "dialect": "regex", "maxLineBytes": 65536]
    }
    guard limit > 0, entryLimit > 0 else { return .error(error: .init(code: .invalidArgument, message: "matchLimit and entryLimit must be positive integers")) }
    if let step {
      guard step.hasPrefix("mv2:"), let bytes = Data(base64Encoded: String(step.dropFirst(4))),
            let cursor = try? JSONDecoder().decode(SearchCursor.self, from: bytes), cursor.machine == machine, cursor.query == canonical,
            cursor.entry >= 0, cursor.line >= 1
      else {
        return .error(error: .init(code: .invalidArgument, message: "malformed or foreign machine search cursor"))
      }
      input["resumeEntries"] = .integer(cursor.entry); input["resumeLine"] = .integer(cursor.line)
    }
    input["matchLimit"] = .integer(limit); input["entryLimit"] = .integer(entryLimit)
    let description = try await describe(machine)
    guard let descriptor = description.kinds.first(where: { $0.name == kind }),
          let properties = descriptor.inputSchema.object?["properties"]?.object,
          ["matchLimit", "resumeEntries", "resumeLine"].allSatisfy({ properties[$0] != nil })
    else {
      throw OperationError(.kindUnavailable, message: "Machine does not support paged \(kind): agent too old, upgrade", details: ["kind": .string(kind), "reason": "agentTooOld", "started": false])
    }
    let id = try await start(machine, request: .init(kind: kind, input: .object(.init(uniqueKeysWithValues: input.map { ($0.key, $0.value) }))), owner: .init(scope: "machine-search/" + UUID().uuidString, key: "operation"))
    var records: [JSONValue] = []; var bytes = 0
    do {
      while true {
        let snapshot = try await poll(id, channel: channel, holdMs: 20000)
        for payload in try await takeOutput(id, channel: channel) {
          bytes += payload.byteCount
          guard bytes <= 16 << 20 else { throw OperationError(.resultTooLarge, operation: id) }
          records += payload.records ?? []
        }
        if snapshot.channelEnd { break }
      }
      let result = try await awaitResult(id)
      _ = try await poll(id, channel: channel, terminalAck: true)
      var next: String?
      if let entry = result.object?["nextEntry"]?.intValue, let line = result.object?["nextLine"]?.intValue {
        next = "mv2:" + (try JSONEncoder().encode(SearchCursor(machine: machine, query: canonical, entry: entry, line: line))).base64EncodedString()
      }
      if kind == "find.v1" {
        return .paths(paths: try records.map { record in
          guard let path = record.object?["path"]?.stringValue else { throw OperationError(.invalidResponse, operation: id) }
          return path
        }, cursor: next)
      }
      return .matches(matches: try records.map { record in
        guard let fields = record.object, let path = fields["path"]?.stringValue,
              let lineString = fields["line"]?.stringValue, let line = Int(lineString), let text = fields["text"]?.stringValue else { throw OperationError(.invalidResponse, operation: id) }
        return SearchMatch(path: path, line: line, text: text, context: [])
      }, cursor: next)
    } catch {
      _ = try? await stop(id, reason: "callerCancelled")
      throw error
    }
  }
}
