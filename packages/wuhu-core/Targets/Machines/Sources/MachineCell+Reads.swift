#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import GroupContract
import struct MachineContract.MachineID
import MachinesContract
import struct OperationProtocol.MachineDescription
import SpaceIDs
import StructuredQueries
import TenancyContract
import WuweiQueries

extension MachineCell: MachineReading {
  private func publicPresence(_ state: String) -> MachineV2Presence? {
    state == "handshaking" ? .attached : MachineV2Presence(rawValue: state)
  }

  public func record() -> MachineRecord? {
    guard let row = db.rows(MachineRow.where { $0.id.eq(id.key) }).first else { return nil }
    return MachineRecord(
      id: MachineID(rawValue: row.id), name: ctx.space().machineName(MachineID(rawValue: id.key)),
      createdAt: (try? SQLiteDateFormat.date(from: row.createdAt)) ?? Date(timeIntervalSince1970: 0),
      group: GroupID(rawValue: row.grp), scope: ReachScope(rawValue: row.scope) ?? .owner,
    )
  }

  func attachedDescription() -> MachineDescription? {
    guard db.rows(MachinePresence.all).first.map({ publicPresence($0.state) }) == .attached else { return nil }
    return machineDescription
  }

  public func presenceEvidence(group: GroupID) -> MachineV2PresenceEvidence? {
    guard let member = db.rows(MachineV2MemberRow.where { $0.machineID.eq(id.key) && $0.grp.eq(group.rawValue) }).first else { return nil }
    guard let row = db.rows(MachinePresence.all).first, row.observed > 0 else {
      return .init(state: .lost, observedAt: try! SQLiteDateFormat.date(from: member.createdAt), reason: "neverAttached")
    }
    let state = publicPresence(row.state)!
    return .init(state: state, observedAt: Date(timeIntervalSince1970: Double(row.observed) / 1000), reason: state == .lost ? "leaseSilence" : nil)
  }
}

public extension MachineCell {
  func group() -> GroupID? { db.rows(MachineRow.where { $0.id.eq(id.key) }).first.map { GroupID(rawValue: $0.grp) } }
}
