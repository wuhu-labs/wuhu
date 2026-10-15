#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import enum JSONValue.JSONValue
import struct SessionDomain.SessionID
import protocol SessionTools.HandlerExecutionClient
import struct SessionTools.ScriptHandlerInvocation
import struct SessionTools.ScriptHandlerResult
import struct WorkerProtocol.WorkerCall
import class WorkerProtocol.WorkerClient
import struct WorkerProtocol.WorkerProtocolError

private struct HandlerInvocationSnapshot: Codable, Sendable {
  let path: String; let session: SessionID; let rows: RowsSnapshot?
  let fireTime: Date?; let stateJSON: String?
  init(_ invocation: ScriptHandlerInvocation) {
    path = invocation.path; session = invocation.session; rows = invocation.rows.map(RowsSnapshot.init)
    fireTime = invocation.fireTime; stateJSON = invocation.stateJSON
  }

  func invocation(id: UUID) throws -> ScriptHandlerInvocation {
    .init(id: id, path: path, session: session, rows: try rows?.value(), fireTime: fireTime, stateJSON: stateJSON)
  }
}

private struct HandlerResultSnapshot: Codable, Sendable {
  let stateJSON: String; let wakes: [String]
  init(_ result: ScriptHandlerResult) { stateJSON = result.stateJSON; wakes = result.wakes }
  var result: ScriptHandlerResult { .init(stateJSON: stateJSON, wakes: wakes) }
}

public struct WorkerHandlerEndpoint: Sendable {
  private let handler: any HandlerExecutionClient
  private let operations = OwnerOperations()
  public init(handler: any HandlerExecutionClient) { self.handler = handler }
  public func invoke(_ call: WorkerCall) async throws -> JSONValue {
    if call.operation == "owner.cancel" {
      let request = try ownerDecode(StreamRequest.self, call.payload)
      await operations.cancel(request.id)
      return .bool(true)
    }
    guard call.operation == "handler.execute" else { throw WorkerProtocolError(.invalidMessage, message: "Unknown worker handler operation") }
    return try await operations.run(call) {
      try await ownerReply {
        let request = try ownerDecode(HandlerInvocationSnapshot.self, call.payload)
        return try await ownerEncode(HandlerResultSnapshot(handler.executeHandler(request.invocation(id: call.id))))
      }
    }
  }

  public func shutdown() async { await operations.stop() }
}

public struct RemoteHandlerExecution: HandlerExecutionClient {
  private let rpc: OwnerRPC
  public init(client: WorkerClient) { rpc = .init(client: client) }
  public func executeHandler(_ invocation: ScriptHandlerInvocation) async throws -> ScriptHandlerResult {
    let call = WorkerCall(id: invocation.id, operation: "handler.execute", payload: try ownerEncode(HandlerInvocationSnapshot(invocation)))
    if let retained = try await rpc.client.retaining(call) {
      let response: HandlerResultSnapshot = try await rpc.retainedCall(retained, consume: false)
      return ScriptHandlerResult(stateJSON: response.stateJSON, wakes: response.wakes, acknowledge: { try? await rpc.acknowledge(retained) })
    }
    let response: HandlerResultSnapshot = try await rpc.call("handler.execute", HandlerInvocationSnapshot(invocation))
    return response.result
  }
}
