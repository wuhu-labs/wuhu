import enum JSONValue.JSONValue
import SessionDomain
import SpaceCore

struct ManipulateUIArguments: Decodable {
  var device: String
  var payload: JSONValue
}

extension ToolExecutor {
  func manipulateUI(_ session: SessionID, _ arguments: ManipulateUIArguments) async throws -> ToolResultPayload {
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
      let n = try await space.issueDeviceCommand(
        device: arguments.device,
        payload: arguments.payload.jsonString(),
        issuedBy: session.rawValue,
      )
      return .manipulateUI(.init(device: arguments.device, n: n))
    } catch let SpaceError.unknownDevice(device) {
      throw ToolProblem("unknown device: \(device); list them with query: SELECT id, name, kind, machine_id FROM devices")
    }
  }
}
