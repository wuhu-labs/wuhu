#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import struct MachineContract.MachineID
import struct SpaceIDs.AccountID
import struct SpaceIDs.GroupID
import struct SpaceIDs.SessionID
import Wuwei

/// One machine cell's reads: the group its row names, and the tail an exec handed back shows.
public protocol MachineReading {
  func group() -> GroupID?
  func tail(_ exec: String) -> Data
}

public struct MachineCells: Sendable {
  public var machine: @Sendable (any CellReading, MachineID) -> any MachineReading

  public init(machine: @escaping @Sendable (any CellReading, MachineID) -> any MachineReading) {
    self.machine = machine
  }
}

extension CellContext {
  public func machine(_ id: MachineID) -> any MachineReading {
    dependency(MachineCells.self).machine(self, id)
  }
}

extension JobContext {
  public func machine(_ id: MachineID) -> any MachineReading {
    dependency(MachineCells.self).machine(self, id)
  }
}

/// The directory cell's reads: the machines as a whole, not one machine's row.
public protocol MachinesReading {
  /// The machine a `machines://` path component names: its id, or a current or retired spelling.
  func machineFolder(_ reference: String) -> String?
  func machineFolders(group: GroupID) -> [MachineFolder]
}

public struct MachinesCells: Sendable {
  public var directory: @Sendable (any CellReading) -> any MachinesReading

  public init(directory: @escaping @Sendable (any CellReading) -> any MachinesReading) {
    self.directory = directory
  }
}

extension CellContext {
  public func machines() -> any MachinesReading {
    dependency(MachinesCells.self).directory(self)
  }
}

extension Reader {
  public func machines() -> any MachinesReading {
    dependency(MachinesCells.self).directory(self)
  }
}

/// Who a machine route acts for: the server maps its principal to this, so no machine code names a tenant type.
public struct MachineCaller: Sendable {
  public enum Kind: Sendable, Equatable {
    case session(SessionID)
    case person(persona: String, account: AccountID)
    case observer(group: GroupID, name: String)
    case page(group: GroupID)
    case publicReader
  }

  public let kind: Kind
  /// The group it acts in.
  public let group: GroupID
  public let member: String?
  /// The groups the caller reads, computed by the server when a machine route asks.
  public let readable: @Sendable () async throws -> Set<GroupID>

  public init(kind: Kind, group: GroupID, member: String?, readable: @escaping @Sendable () async throws -> Set<GroupID>) {
    self.kind = kind; self.group = group; self.member = member; self.readable = readable
  }

  public var session: SessionID? {
    if case let .session(id) = kind { id } else { nil }
  }

  public var account: AccountID? {
    if case let .person(_, account) = kind { account } else { nil }
  }

  public var observerMember: String? {
    if case let .observer(_, name) = kind { name } else { nil }
  }
}

public enum ExecLeg: Hashable, Sendable {
  case session(SessionID)
  case person(AccountID)
  case observer(String)

  /// Nil for a page or a public reader, which attaches to no exec.
  public init?(_ caller: MachineCaller) {
    switch caller.kind {
    case let .session(id): self = .session(id)
    case let .person(_, account): self = .person(account)
    case let .observer(group, name): self = .observer("\(name)@\(group.rawValue)")
    case .page, .publicReader: return nil
    }
  }

  public var session: SessionID? { if case let .session(id) = self { id } else { nil } }
}
