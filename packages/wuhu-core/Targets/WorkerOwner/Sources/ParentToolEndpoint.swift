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

struct ParentToolEndpoint: Sendable {
  let owner: any ToolOwnerClient
  func invoke(_ call: WorkerCall) async throws -> JSONValue {
    try await ownerReply {
      switch call.operation {
      case "tool.execute":
        let request = try ownerDecode(ExecuteToolRequest.self, call.payload)
        return try ownerEncode(await owner.execute(session: request.session, call: request.call, state: request.state.value))
      case "tool.kill-interrupted-exec":
        let request = try ownerDecode(ToolCallRequest.self, call.payload)
        await owner.killInterruptedExec(session: request.session, toolCallID: request.call)
        return .bool(true)
      case "tool.refuse-unless-live":
        let request = try ownerDecode(SessionIDRequest.self, call.payload)
        try await owner.refuseUnlessLive(request.id)
        return .bool(true)
      case "tool.spawn":
        let request = try ownerDecode(SpawnRequest.self, call.payload)
        return try ownerEncode(SpawnedSnapshot(await owner.spawn(request.session, request.call, request.order.order)))
      case "tool.send-message":
        let request = try ownerDecode(ToolMessageRequest.self, call.payload)
        return try ownerEncode(await owner.sendMessage(request.caller, request.call, request.arguments))
      case "tool.request":
        let request = try ownerDecode(ToolRequestRequest.self, call.payload)
        return try ownerEncode(await owner.request(request.caller, request.call, request.arguments))
      case "tool.set-tags":
        let request = try ownerDecode(ToolTagsRequest.self, call.payload)
        try await owner.setTags(request.caller, of: request.target, to: request.tags)
        return .bool(true)
      case "tool.control":
        let request = try ownerDecode(ToolControlRequest.self, call.payload)
        guard let verb = SessionControl.Verb(rawValue: request.verb) else { throw WorkerProtocolError(.invalidMessage, message: "Invalid session control verb") }
        try await owner.control(verb, request.caller, of: request.target, force: request.force)
        return .bool(true)
      case "tool.capability-document":
        let request = try ownerDecode(CapabilityPathRequest.self, call.payload)
        return try ownerEncode(await owner.capabilityDocument(request.path))
      case "tool.capability-input":
        let request = try ownerDecode(CapabilityInputRequest.self, call.payload)
        return try ownerEncode(await owner.capabilityInput(request.raw, as: request.session, limit: request.limit))
      case "tool.record-completion":
        let request = try ownerDecode(MetricSnapshot.self, call.payload)
        try await owner.recordCompletion(request.metric())
        return .bool(true)
      case "tool.resolve-image-destination":
        let request = try ownerDecode(ImagePathRequest.self, call.payload)
        return try ownerEncode(AddressSnapshot(await owner.resolveImageDestination(request.raw, session: request.session)))
      case "tool.refuse-image-destination":
        let request = try ownerDecode(ImageDestinationRequest.self, call.payload)
        try await owner.refuseImageDestination(request.destination.value(), session: request.session)
        return .bool(true)
      case "tool.image-receipt":
        let request = try ownerDecode(ToolCallRequest.self, call.payload)
        return try ownerEncode(await owner.imageReceipt(request.session, call: request.call))
      case "tool.place-image":
        let request = try ownerDecode(PlaceImageRequest.self, call.payload)
        return try ownerEncode(await owner.placeImage(request.image, at: request.destination.value(), session: request.session, call: request.call, state: request.state?.value))
      default: throw WorkerProtocolError(.invalidMessage, message: "Unknown parent tool operation")
      }
    }
  }
}
