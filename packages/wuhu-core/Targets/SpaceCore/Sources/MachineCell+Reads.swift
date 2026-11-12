#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import struct OperationProtocol.MachineDescription
import struct SpaceContract.GroupID
import SpaceFS
import StructuredQueries
import WuweiQueries

extension MachineCell {
  func record() -> MachineRecord? {
    db.rows(MachineRow.where { $0.id.eq(id.key) }).first.map(Space.machineRecord(from:))
  }

  func attachedDescription() -> MachineDescription? {
    guard db.rows(MachinePresence.all).first?.state == "attached" else { return nil }
    return machineDescription
  }

  func presenceEvidence(group: GroupID) -> MachineV2PresenceEvidence? {
    guard let member = db.rows(MachineV2MemberRow.where { $0.machineID.eq(id.key) && $0.grp.eq(group.rawValue) }).first else { return nil }
    guard let row = db.rows(MachinePresence.all).first, row.observed > 0 else {
      return .init(state: .lost, observedAt: try! SQLiteDateFormat.date(from: member.createdAt), reason: "neverAttached")
    }
    let state = MachineV2Presence(rawValue: row.state)!
    return .init(state: state, observedAt: Date(timeIntervalSince1970: Double(row.observed) / 1000), reason: state == .lost ? "leaseSilence" : nil)
  }
}
