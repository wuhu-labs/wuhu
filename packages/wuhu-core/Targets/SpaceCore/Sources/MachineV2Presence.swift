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

  public func machineV2DetachedMembers(group: GroupID) async throws -> Set<String> {
    try await writer.read { db in
      Set(try MachineV2PresenceRow.where { $0.grp.eq(group.rawValue) && $0.state.eq("detached") }.fetchAll(db).map(\.machineID))
    }
  }

  public func machineV2PresenceEvidence(_ machine: String, group: GroupID) async throws -> MachineV2PresenceEvidence? {
    try await writer.read { db in
      let state: MachineV2Presence
      let stamp: String
      let reason: String?
      if let row = try MachineV2PresenceRow.where({ $0.machineID.eq(machine) && $0.grp.eq(group.rawValue) }).fetchOne(db) {
        guard let stored = MachineV2Presence(rawValue: row.state) else { throw OperationError(.storeUnavailable, message: "Machine v2 presence evidence is invalid") }
        state = stored; stamp = row.observedAt; reason = row.reason
      } else if let member = try MachineV2MemberRow.where({ $0.machineID.eq(machine) && $0.grp.eq(group.rawValue) }).fetchOne(db) {
        state = .lost; stamp = member.createdAt; reason = "neverAttached"
      } else { return nil }
      let observedAt: Date
      do { observedAt = try SQLiteDateFormat.date(from: stamp) }
      catch { throw OperationError(.storeUnavailable, message: "Machine v2 presence evidence is invalid") }
      return .init(state: state, observedAt: observedAt, reason: reason)
    }
  }

  /// A connection alone is not evidence; the coordinator supplies this only after describe, settled leave, or local lease expiry.
  public func recordMachineV2Presence(_ machine: String, group: GroupID, state: MachineV2Presence, description: MachineDescription? = nil, reason: String? = nil) async throws {
    guard state != .attached || description != nil else { throw OperationError(.invalidInput) }
    let stamp = SQLiteDateFormat.string(from: dateGen.now)
    let json = try description.map { String(decoding: try JSONEncoder().encode($0), as: UTF8.self) }
    try await writer.write { db in
      guard let member = try MachineV2MemberRow.where({ $0.machineID.eq(machine) && $0.grp.eq(group.rawValue) }).fetchOne(db) else { throw OperationError(.unknownMachine) }
      let prior = try MachineV2PresenceRow.where { $0.machineID.eq(machine) && $0.grp.eq(group.rawValue) }.fetchOne(db)
      let observedAt: String
      if state == .lost { observedAt = prior?.observedAt ?? member.createdAt }
      else { observedAt = stamp }
      let row = MachineV2PresenceRow(machineID: machine, grp: group.rawValue, state: state.rawValue, description: json, observedAt: observedAt, reason: reason)
      try MachineV2PresenceRow.upsert { row }.execute(db)
    }
  }
}
