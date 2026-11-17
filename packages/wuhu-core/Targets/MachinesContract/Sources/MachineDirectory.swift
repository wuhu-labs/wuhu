import struct MachineContract.ExecID
import struct MachineContract.MachineID
import struct SessionDomain.ToolCallID
import struct SpaceIDs.GroupID
import Wuwei

/// What another family asks machines out of step: the machine directory's reads, the exec records, and the call that
/// reserves an exec. The machine family implements it; the server supplies it.
public struct MachineDirectory: Sendable {
  public var machine: @Sendable (MachineID) async throws -> MachineRecord?
  public var usable: @Sendable (GroupID) async throws -> [MachineRecord]
  public var resolve: @Sendable (String) async throws -> MachineRecord?
  public var resolveUsable: @Sendable (String, GroupID) async throws -> MachineRecord?
  public var canUse: @Sendable (MachineRecord, GroupID) async throws -> Bool
  public var exec: @Sendable (ExecID) async throws -> ExecRecord?
  public var liveExecs: @Sendable () async throws -> [ExecRecord]
  public var liveToolExecs: @Sendable (String) async throws -> [ExecRecord]
  public var reserveExec: @Sendable (MachineID, String?, GroupID?, String?, ToolCallID?) async throws -> ExecRecord

  public init(
    machine: @escaping @Sendable (MachineID) async throws -> MachineRecord?,
    usable: @escaping @Sendable (GroupID) async throws -> [MachineRecord],
    resolve: @escaping @Sendable (String) async throws -> MachineRecord?,
    resolveUsable: @escaping @Sendable (String, GroupID) async throws -> MachineRecord?,
    canUse: @escaping @Sendable (MachineRecord, GroupID) async throws -> Bool,
    exec: @escaping @Sendable (ExecID) async throws -> ExecRecord?,
    liveExecs: @escaping @Sendable () async throws -> [ExecRecord],
    liveToolExecs: @escaping @Sendable (String) async throws -> [ExecRecord],
    reserveExec: @escaping @Sendable (MachineID, String?, GroupID?, String?, ToolCallID?) async throws -> ExecRecord,
  ) {
    self.machine = machine
    self.usable = usable
    self.resolve = resolve
    self.resolveUsable = resolveUsable
    self.canUse = canUse
    self.exec = exec
    self.liveExecs = liveExecs
    self.liveToolExecs = liveToolExecs
    self.reserveExec = reserveExec
  }
}

/// A machine's folder in its group's tree: the notes are stored by id and listed under the machine's current name.
public struct MachineFolder: Sendable, Equatable {
  public let id: String
  public let name: String?

  public init(id: String, name: String?) {
    self.id = id; self.name = name
  }
}
