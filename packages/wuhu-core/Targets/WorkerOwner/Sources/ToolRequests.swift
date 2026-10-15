#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import struct MachineContract.MachineID
import struct SessionDomain.SessionID
import struct SessionDomain.SubscriptionID
import struct SessionDomain.ToolCallID
import struct SessionDomain.ToolExecutionState
import enum SessionTools.Address
import struct SessionTools.RequestArguments
import struct SessionTools.SendMessageArguments
import struct SpaceContract.GroupID
import struct WorkerProtocol.WorkerProtocolError
import struct WuhuAI.ToolCall

struct ToolStateSnapshot: Codable, Sendable {
  let state: ToolExecutionState
  let handlers: Set<SubscriptionID>
  init(_ state: ToolExecutionState) { self.state = state; handlers = state.handlerSubscriptions }
  var value: ToolExecutionState {
    var result = state
    result.handlerSubscriptions = handlers
    return result
  }
}

struct AddressSnapshot: Codable, Sendable {
  let kind: String
  let path: String
  let group: GroupID?
  let machine: MachineID?
  let qualified: Bool?
  init(_ address: Address) {
    switch address {
    case let .space(path, group, qualified): self.path = path; self.group = group; self.qualified = qualified; machine = nil; kind = "space"
    case let .machine(machine, path): self.path = path; self.machine = machine; group = nil; qualified = nil; kind = "machine"
    case let .system(path): self.path = path; group = nil; machine = nil; qualified = nil; kind = "system"
    }
  }

  func value() throws -> Address {
    switch kind {
    case "space" where machine == nil:
      if let group, let qualified { return .space(path, in: group, qualified: qualified) }
    case "machine" where group == nil && qualified == nil:
      if let machine { return .machine(machine, path) }
    case "system" where group == nil && machine == nil && qualified == nil: return .system(path)
    default: break
    }
    throw WorkerProtocolError(.invalidMessage, message: "Invalid address snapshot")
  }
}

struct ExecuteToolRequest: Codable, Sendable { let session: SessionID; let call: ToolCall; let state: ToolStateSnapshot }
struct ToolCallRequest: Codable, Sendable { let session: SessionID; let call: ToolCallID }
struct ToolTagsRequest: Codable, Sendable { let caller: SessionID; let target: SessionID; let tags: [String] }
struct ToolControlRequest: Codable, Sendable { let verb: String; let caller: SessionID; let target: SessionID; let force: Bool }
struct CapabilityPathRequest: Codable, Sendable { let path: String }
struct CapabilityInputRequest: Codable, Sendable { let raw: String; let session: SessionID; let limit: Int }
struct ImagePathRequest: Codable, Sendable { let raw: String; let session: SessionID }
struct ImageDestinationRequest: Codable, Sendable { let destination: AddressSnapshot; let session: SessionID }
struct PlaceImageRequest: Codable, Sendable { let image: Data; let destination: AddressSnapshot; let session: SessionID; let call: ToolCallID?; let state: ToolStateSnapshot? }
struct ToolMessageRequest: Codable, Sendable {
  let caller: SessionID
  let call: ToolCallID
  let message: String
  let conversation: String?
  let session: String?
  let replyTarget: String?
  let attachments: [String]?
  init(_ caller: SessionID, _ call: ToolCallID, _ arguments: SendMessageArguments) {
    self.caller = caller; self.call = call; message = arguments.message; conversation = arguments.conversation; session = arguments.session; replyTarget = arguments.replyTarget; attachments = arguments.attachments
  }

  var arguments: SendMessageArguments { .init(message: message, conversation: conversation, session: session, replyTarget: replyTarget, attachments: attachments) }
}

struct ToolRequestRequest: Codable, Sendable {
  let caller: SessionID
  let call: ToolCallID
  let task: String
  let message: String
  let deadlineSeconds: Double?
  init(_ caller: SessionID, _ call: ToolCallID, _ arguments: RequestArguments) {
    self.caller = caller; self.call = call; task = arguments.task; message = arguments.message; deadlineSeconds = arguments.deadlineSeconds
  }

  var arguments: RequestArguments { .init(task: task, message: message, deadlineSeconds: deadlineSeconds) }
}
