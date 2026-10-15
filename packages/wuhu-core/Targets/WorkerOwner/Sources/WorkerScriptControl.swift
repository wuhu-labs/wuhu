#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import enum JSONValue.JSONValue
import struct SessionDomain.SessionID
import enum SessionDomain.ToolResultPayload
import class SessionTools.Scripts
import struct WorkerProtocol.WorkerCall
import class WorkerProtocol.WorkerClient

public struct WorkerScriptControl: Sendable {
  private let rpc: OwnerRPC
  public init(client: WorkerClient) { rpc = .init(client: client) }

  public func stop(_ script: String, session: SessionID) async throws -> ToolResultPayload {
    try await rpc.client.requireCapability(ExecutionWorkerBootstrap.handoffCapability)
    return try await rpc.call("execution.stop-script", ScriptActivity(session: session, script: script))
  }

  public static func invoke(_ call: WorkerCall, scripts: Scripts) async throws -> JSONValue {
    try await ownerReply {
      let request = try ownerDecode(ScriptActivity.self, call.payload)
      return try await ownerEncode(scripts.stop(request.script, session: request.session))
    }
  }
}
