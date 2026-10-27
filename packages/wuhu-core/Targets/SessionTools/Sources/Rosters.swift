import struct MachineContract.MachineStatus
import SessionDomain
import SpaceContract
import SpaceCore

// What the session may reach: the machines usable from its group, and the
// session templates its group defines.
extension ToolExecutor {
  func machines(_ session: SessionID, _ call: String) async throws -> ToolResultPayload {
    let statuses: [MachineStatus] = try await verb(.session(session), call, .get, "/v1/machine")
    return .machines(.init(machines: statuses.map { MachineListing(id: $0.id.rawValue, name: $0.name, attached: $0.attached) }))
  }

  func templates(_ session: SessionID, _ call: String) async throws -> ToolResultPayload {
    let listed: SessionTemplatesOutput = try await verb(.session(session), call, .get, "/v1/templates")
    return .templates(.init(templates: listed.templates.map { template in
      TemplateListing(
        name: template.name, kind: template.kind?.rawValue, provider: template.provider, model: template.model,
        effort: template.effort, description: template.description, modelGroup: template.modelGroup,
      )
    }))
  }
}
