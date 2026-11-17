import AgentsContract
import struct MachineContract.MachineID
import Machines
import MachinesContract
import SpaceCore
import struct SpaceIDs.GroupID

/// Who a machine route's request acts for, from the principal the server resolved.
func machineCallerVerdict(_ verdict: PrincipalVerdict, space: Space) -> MachinePrincipalVerdict {
  switch verdict {
  case let .principal(principal): .caller(machineCaller(principal, space: space))
  case let .refused(response): .refused(response)
  }
}

func machineCaller(_ principal: Principal, space: Space) -> MachineCaller {
  let kind: MachineCaller.Kind = switch principal.actor {
  case let .session(id): .session(id)
  case let .person(persona, account): .person(persona: persona, account: account)
  case let .observer(observer): .observer(group: observer.group, name: observer.name)
  case let .page(page): .page(group: page.group)
  case .publicReader: .publicReader
  }
  return MachineCaller(kind: kind, group: principal.group, member: principal.member) {
    try await space.reads(for: principal)
  }
}
