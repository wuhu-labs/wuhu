import SessionDomain
import SpaceCore
import struct SpaceIDs.GroupID

extension Hub {
  nonisolated public func machineRoster(_ group: GroupID) async throws -> ToolResultPayload {
    guard let machines else {
      throw ToolProblem("no machine backend is available on this server")
    }
    let attached = await machines.attached()
    let listings = try await space.machines(usableFrom: group).map { record in
      MachineListing(id: record.id.rawValue, name: record.name, attached: attached.contains(record.id))
    }
    return .machines(.init(machines: listings))
  }
}
