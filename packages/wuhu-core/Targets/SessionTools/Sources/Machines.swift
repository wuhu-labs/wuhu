import SessionDomain
import SpaceCore

extension ToolExecutor {
  func machineRoster(_ session: SessionID) async throws -> ToolResultPayload {
    guard let machines else {
      throw ToolProblem("no machine backend is available on this server")
    }
    let attached = await machines.attached()
    let group = try await space.principal(of: session).group
    let listings = try await space.machines(usableFrom: group).map { record in
      MachineListing(id: record.id.rawValue, name: record.name, attached: attached.contains(record.id))
    }
    return .machines(.init(machines: listings))
  }
}
