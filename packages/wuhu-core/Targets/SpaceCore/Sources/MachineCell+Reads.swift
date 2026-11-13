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
  private func publicPresence(_ state: String) -> MachineV2Presence? {
    state == "handshaking" ? .attached : MachineV2Presence(rawValue: state)
  }

  func record() -> MachineRecord? {
    guard let row = db.rows(MachineRow.where { $0.id.eq(id.key) }).first else { return nil }
    let name = db.rows(AliasRow.where { $0.kind.eq(AliasKind.machine) && $0.target.eq(id.key) && $0.current }).first?.name
    return Space.machineRecord(from: row, name: name)
  }

  func attachedDescription() -> MachineDescription? {
    guard db.rows(MachinePresence.all).first.map({ publicPresence($0.state) }) == .attached else { return nil }
    return machineDescription
  }

  func presenceEvidence(group: GroupID) -> MachineV2PresenceEvidence? {
    guard let member = db.rows(MachineV2MemberRow.where { $0.machineID.eq(id.key) && $0.grp.eq(group.rawValue) }).first else { return nil }
    guard let row = db.rows(MachinePresence.all).first, row.observed > 0 else {
      return .init(state: .lost, observedAt: try! SQLiteDateFormat.date(from: member.createdAt), reason: "neverAttached")
    }
    let state = publicPresence(row.state)!
    return .init(state: state, observedAt: Date(timeIntervalSince1970: Double(row.observed) / 1000), reason: state == .lost ? "leaseSilence" : nil)
  }
}
