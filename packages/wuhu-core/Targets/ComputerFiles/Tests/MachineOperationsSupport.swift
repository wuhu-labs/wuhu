#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import Fetch
import enum JSONValue.JSONValue
import OperationClient
import struct OperationProtocol.Verdict

/// Server-side operations over one in-process agent.
func machineOperations(_ handler: @escaping @Sendable (Request) async throws -> Response) throws -> MachineOperations {
  try MachineOperations(origin: URL(string: "https://test.invalid")!, fetch: FetchClient { try await handler($0) }, store: MemoryOperationStore())
}

/// How an operation ended, as the tests read it.
struct Ending: Sendable {
  let verdict: Verdict?
}

extension OperationClient.Operation {
  /// Reads and acknowledges every output chunk until the operation is drained, then waits for its verdict.
  func drain() async throws -> (data: Data, records: [JSONValue], end: Ending) {
    var data = Data()
    var records: [JSONValue] = []
    var after: UInt64?
    while let chunks = try await output(after: after) {
      for chunk in chunks {
        data.append(chunk.payload.data ?? Data())
        records += chunk.payload.records ?? []
        try await acknowledge(chunk)
        after = chunk.sequence
      }
    }
    return try await (data, records, Ending(verdict: verdict()))
  }
}

/// Receipt retention for an agent whose clock jumps past its lease: the stopped operation's verdict outlives the jump, as it
/// would for a server still polling.
let leaseJumpRetention: Duration = .seconds(3600)
