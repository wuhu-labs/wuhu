#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import struct InferenceKit.InferenceMetric
import enum JSONValue.JSONValue
import struct SessionDomain.SessionID
import struct SessionDomain.ToolCallID
import struct SessionDomain.ToolExecutionState
import enum SessionDomain.ToolResultPayload
import enum SessionTools.Address
import struct SessionTools.RequestArguments
import struct SessionTools.SendMessageArguments
import struct SessionTools.SessionControl
import struct SessionTools.Spawned
import struct SessionTools.SpawnOrder
import protocol SessionTools.ToolOwnerClient
import struct WorkerProtocol.WorkerCall
import struct WorkerProtocol.WorkerProtocolError
import struct WuhuAI.ToolCall

extension RemoteExecutionOwner {
  public func killInterruptedExec(session: SessionID, toolCallID: ToolCallID) async {
    await Task { [rpc] in
      let _: Bool? = try? await rpc.call("tool.kill-interrupted-exec", ToolCallRequest(session: session, call: toolCallID))
    }.value
  }

  public func execute(session: SessionID, call: ToolCall, state: ToolExecutionState) async throws -> ToolResultPayload {
    try await rpc.call("tool.execute", ExecuteToolRequest(session: session, call: call, state: .init(state)))
  }

  public func refuseUnlessLive(_ session: SessionID) async throws {
    let _: Bool = try await rpc.call("tool.refuse-unless-live", SessionIDRequest(id: session))
  }

  public func spawn(_ caller: SessionID, _ call: ToolCallID, _ order: SpawnOrder) async throws -> Spawned {
    let result: SpawnedSnapshot = try await rpc.call("tool.spawn", SpawnRequest(session: caller, call: call, order: .init(order)))
    return result.spawned
  }

  public func sendMessage(_ caller: SessionID, _ call: ToolCallID, _ arguments: SendMessageArguments) async throws -> ToolResultPayload {
    try await rpc.call("tool.send-message", ToolMessageRequest(caller, call, arguments))
  }

  public func request(_ caller: SessionID, _ call: ToolCallID, _ arguments: RequestArguments) async throws -> ToolResultPayload {
    try await rpc.call("tool.request", ToolRequestRequest(caller, call, arguments))
  }

  public func setTags(_ caller: SessionID, of target: SessionID, to tags: [String]) async throws {
    let _: Bool = try await rpc.call("tool.set-tags", ToolTagsRequest(caller: caller, target: target, tags: tags))
  }

  public func control(_ verb: SessionControl.Verb, _ caller: SessionID, of target: SessionID, force: Bool) async throws {
    let _: Bool = try await rpc.call("tool.control", ToolControlRequest(verb: verb.rawValue, caller: caller, target: target, force: force))
  }

  public func capabilityDocument(_ path: String) async throws -> Data? {
    try await rpc.call("tool.capability-document", CapabilityPathRequest(path: path))
  }

  public func capabilityInput(_ raw: String, as session: SessionID, limit: Int) async throws -> Data {
    try await rpc.call("tool.capability-input", CapabilityInputRequest(raw: raw, session: session, limit: limit))
  }

  public func recordCompletion(_ metric: InferenceMetric) async throws {
    let _: Bool = try await rpc.call("tool.record-completion", MetricSnapshot(metric))
  }

  public func resolveImageDestination(_ raw: String, session: SessionID) async throws -> Address {
    let result: AddressSnapshot = try await rpc.call("tool.resolve-image-destination", ImagePathRequest(raw: raw, session: session))
    return try result.value()
  }

  public func refuseImageDestination(_ destination: Address, session: SessionID) async throws {
    let _: Bool = try await rpc.call("tool.refuse-image-destination", ImageDestinationRequest(destination: .init(destination), session: session))
  }

  public func imageReceipt(_ session: SessionID, call: ToolCallID) async throws -> ToolResultPayload? {
    try await rpc.call("tool.image-receipt", ToolCallRequest(session: session, call: call))
  }

  public func placeImage(_ image: Data, at destination: Address, session: SessionID, call: ToolCallID?, state: ToolExecutionState?) async throws -> ToolResultPayload {
    try await rpc.call("tool.place-image", PlaceImageRequest(image: image, destination: .init(destination), session: session, call: call, state: state.map(ToolStateSnapshot.init)))
  }
}
