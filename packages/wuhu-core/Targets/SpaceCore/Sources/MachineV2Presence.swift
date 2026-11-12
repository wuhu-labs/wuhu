#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import GRDB
import struct OperationProtocol.MachineDescription
import struct OperationProtocol.OperationError
import struct SpaceContract.GroupID
import SpaceFS
import StructuredQueries
import StructuredQueriesSQLite

public enum MachineV2Presence: String, Sendable { case attached, detached, lost }

public struct MachineV2PresenceEvidence: Sendable {
  public let state: MachineV2Presence
  public let observedAt: Date
  public let reason: String?
}

extension Space {
  public func registerMachineV2(_ machine: String, group: GroupID) async throws {
    guard let record = try await resolveMachine(machine, usableFrom: group), record.id.rawValue == machine, record.group == group else { throw OperationError(.unknownMachine) }
    let stamp = SQLiteDateFormat.string(from: dateGen.now)
    try await writer.write { db in
      let row = MachineV2MemberRow(machineID: machine, grp: group.rawValue, createdAt: stamp)
      try MachineV2MemberRow.upsert { row }.execute(db)
    }
  }

  public func machineV2Members(group: GroupID) async throws -> [String] {
    try await writer.read { db in try MachineV2MemberRow.where { $0.grp.eq(group.rawValue) }.fetchAll(db).map(\.machineID) }
  }

  public func machineV2PresenceEvidence(_ machine: String, group: GroupID) async throws -> MachineV2PresenceEvidence? {
    try await writer.read { db in
      guard let member = try MachineV2MemberRow.where({ $0.machineID.eq(machine) && $0.grp.eq(group.rawValue) }).fetchOne(db) else { return nil }
      guard let row = try MachinePresence.unscoped.where({ _ in #sql("owner", as: String.self).eq(machine) }).fetchOne(db), row.observed > 0 else {
        return .init(state: .lost, observedAt: try SQLiteDateFormat.date(from: member.createdAt), reason: "neverAttached")
      }
      let state = MachineV2Presence(rawValue: row.state) ?? .lost
      return .init(state: state, observedAt: Date(timeIntervalSince1970: Double(row.observed) / 1000), reason: state == .lost ? "leaseSilence" : nil)
    }
  }
}
