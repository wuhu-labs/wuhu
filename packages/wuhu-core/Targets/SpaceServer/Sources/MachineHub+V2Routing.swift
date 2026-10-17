import struct MachineContract.MachineID
import struct OperationProtocol.OperationError
import struct SpaceContract.GroupID

extension MachineHub {
  func configureV2(_ service: MachineV2Service) { v2 = service }

  func v2Group(_ machine: MachineID) async throws -> GroupID? {
    if legacyMachines.contains(machine) { return nil }
    guard let record = try await space.machine(machine) else { return nil }
    if try await space.machineV2Members(group: record.group).contains(machine.rawValue) { return record.group }
    if legacyMachines.count < 4096 { legacyMachines.insert(machine) }
    return nil
  }

  func requireExecKind(_ machine: MachineID) async throws {
    guard let group = try await v2Group(machine) else { return }
    guard let v2 else { throw OperationError(.machineUnavailable, message: "Machine v2 is unavailable") }
    let description = try await v2.operations(group: group).describe(machine.rawValue)
    guard description.kinds.contains(where: { $0.name == "exec.v1" }) || description.availability?["exec.v1"] != nil else {
      throw OperationError(.unknownKind, message: "Machine does not support exec.v1", details: ["kind": "exec.v1"])
    }
  }
}
