#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import struct FileSearch.SearchError
import struct FileSearch.SearchPage
import struct FileSearch.SearchQuery
import enum JSONValue.JSONValue
import struct OperationProtocol.OperationError
import struct OperationProtocol.StartRequest

public extension MachineOperations {
  /// One page of `query` on `machine`'s disk, through `search.v1`. The
  /// search's own failures are ``SearchError``s; a machine without `search.v1`
  /// refuses with `kindUnavailable` (`agentTooOld`) before anything starts.
  func search(machine: String, query: SearchQuery, caller: StartRequest.Caller? = nil) async throws -> SearchPage {
    let description = if let recent = recentDescription(machine) { recent } else { try await describe(machine) }
    guard description.kinds.contains(where: { $0.name == "search.v1" }) else {
      throw OperationError(.kindUnavailable, message: "Machine does not support search.v1: agent too old, upgrade", details: ["kind": "search.v1", "reason": "agentTooOld", "started": false])
    }
    let input = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(query))
    let result: JSONValue
    do {
      result = try await call(machine, .init(scope: "machine-search/" + UUID().uuidString, key: "operation"), .init(kind: "search.v1", input: input, caller: caller))
    } catch let error as OperationError {
      if case let .string(code)? = error.details?.object?["search"], let typed = SearchError.Code(rawValue: code) { throw SearchError(typed, error.message) }
      throw error
    }
    do { return try JSONDecoder().decode(SearchPage.self, from: Data(result.jsonString().utf8)) }
    catch { throw OperationError(.invalidResponse, message: "search.v1 result is not a page") }
  }
}
