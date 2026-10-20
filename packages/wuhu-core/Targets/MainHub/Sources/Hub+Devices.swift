import enum JSONValue.JSONValue
import SessionDomain
import SpaceCore

public struct ManipulateUIArguments: Decodable, Sendable {
  public var device: String
  public var payload: JSONValue

  public init(device: String, payload: JSONValue) { self.device = device; self.payload = payload }
}

extension Hub {
  // The answer is looked up and recorded in the write that issues the
  // command: a retry of the call, or a twin of it running at once, drives
  // the device once.
  nonisolated public func manipulateUI(_ session: SessionID, _ callID: ToolCallID, _ arguments: ManipulateUIArguments) async throws -> ToolResultPayload {
    guard case .object = arguments.payload else {
      throw ToolProblem("manipulate_ui: payload is a JSON object, e.g. {\"sidebar\": \"everything\"}")
    }
    // A device is driven by top-level agents only, never by a task
    // or a child agent.
    let record = try await store.record(session)
    guard record.kind == .agent, record.parent == nil else {
      throw ToolProblem("manipulate_ui is for top-level agents; a task or child agent may not drive a device")
    }
    do {
      return try await space.issueDeviceCommand(
        device: arguments.device,
        payload: arguments.payload.jsonString(),
        issuedBy: session,
        answering: callID,
      )
    } catch let SpaceError.unknownDevice(device) {
      throw ToolProblem("unknown device: \(device); list them with query: SELECT id, name, kind, machine_id FROM devices")
    }
  }
}
