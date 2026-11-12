#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import GRDB
import struct MachineContract.ExecID
import struct MachineContract.MachineID
import struct SessionDomain.SessionID
import struct SessionDomain.ToolCallID
import struct SpaceContract.GroupID
import func SpaceContract.normalizedLabel
import SpaceFS
import StructuredQueries
import StructuredQueriesSQLite

public struct MachineRecord: Equatable, Sendable {
  public let id: MachineID
  public let account: AccountID
  public let name: String?
  public let createdAt: Date
  /// The group the machine belongs to: groups that can use it may exec on it.
  public let group: GroupID
  /// Who may use it: its own group, or every group that can reach that one.
  public let scope: ReachScope

  public init(id: MachineID, account: AccountID, name: String?, createdAt: Date, group: GroupID, scope: ReachScope = .owner) {
    self.id = id; self.account = account; self.name = name; self.createdAt = createdAt; self.group = group; self.scope = scope
  }
}

public enum MachineName {
  public static func normalized(_ raw: String) -> String? {
    let mapped = raw.replacingOccurrences(of: "-", with: "_")
    guard !MachineID.isValid(mapped.lowercased()) else { return nil }
    return normalizedLabel(mapped, allowing: ["_", "."], length: 1 ... 63)
  }
}

public enum ExecTerminalState: Equatable, Sendable, Codable {
  case exited(code: Int)
  case signaled(signal: Int)
  case cancelled
  case reaped
  case machineLost

  var stored: String {
    switch self {
    case let .exited(code): "exited:\(code)"
    case let .signaled(signal): "signaled:\(signal)"
    case .cancelled: "cancelled"
    case .reaped: "reaped"
    case .machineLost: "machine-lost"
    }
  }

  init?(stored: String) {
    switch stored {
    case "cancelled": self = .cancelled
    case "reaped": self = .reaped
    case "machine-lost": self = .machineLost
    default:
      let parts = stored.split(separator: ":", maxSplits: 1)
      guard parts.count == 2, let value = Int(parts[1]) else { return nil }
      switch parts[0] {
      case "exited": self = .exited(code: value)
      case "signaled": self = .signaled(signal: value)
      default: return nil
      }
    }
  }
}

public struct ExecRecord: Equatable, Sendable, Codable {
  public let id: ExecID
  public let machine: MachineID
  public let streamID: Int
  public let command: String
  public let caller: String?
  public let toolCallID: ToolCallID?
  public let toolSpec: String?
  /// Its tool call answered `running`: the relay keeps it without a caller and tells the session how it ended.
  public let background: Bool
  public let startedAt: Date
  public let terminal: ExecTerminalState?
  public let killDelivered: Bool
  /// The group the exec is homed in: groups that read it may see and join it.
  public let group: GroupID

  public init(id: ExecID, machine: MachineID, streamID: Int, command: String, caller: String?, toolCallID: ToolCallID?, startedAt: Date, terminal: ExecTerminalState?, killDelivered: Bool, group: GroupID, toolSpec: String? = nil, background: Bool = false) {
    self.id = id; self.machine = machine; self.streamID = streamID; self.command = command; self.caller = caller; self.toolCallID = toolCallID; self.startedAt = startedAt; self.terminal = terminal; self.killDelivered = killDelivered; self.group = group; self.toolSpec = toolSpec; self.background = background
  }

  /// The session that minted it: nil for an observer's, whose caller is its member.
  public var session: SessionID? { caller.flatMap { Observer.isMember($0) ? nil : SessionID(rawValue: $0) } }
}

extension Space {
  /// A machine enrolled by a person joins that person's group; `shared` holds
  /// every machine from before groups.
  public func addMachine(name: String?, group: GroupID = .shared, scope: ReachScope = .owner) async throws -> MachineRecord {
    let requested = try name.map { try Self.requireMachineName($0) }
    let id = MachineID(rawValue: "mc_" + randomSuffix(MachineID.suffixLength))
    let account = AccountID(rawValue: AccountID.prefix + randomSuffix(AccountID.suffixLength))
    let createdAt = dateGen.now
    let stored = SQLiteDateFormat.string(from: createdAt)
    try await writer.write { db in
      if let requested { try Self.requireMachineNameFree(requested, for: id, group: group, in: db) }
      try db.execute(
        sql: "INSERT INTO accounts (id, kind, name, created_at) VALUES (?, ?, ?, ?)",
        arguments: [account.rawValue, AccountKind.machine.rawValue, requested, stored],
      )
      try MachineRow.insert {
        MachineRow(
          id: id.rawValue, accountID: account.rawValue, name: requested, createdAt: stored, grp: group.rawValue,
          scope: scope.rawValue,
        )
      }.execute(db)
    }
    return MachineRecord(id: id, account: account, name: requested, createdAt: createdAt, group: group, scope: scope)
  }

  public func renameMachine(_ id: MachineID, name: String) async throws -> MachineRecord {
    let requested = try Self.requireMachineName(name)
    return try await writer.write { db in
      guard let row = try MachineRow.where({ $0.id.eq(id.rawValue) }).fetchOne(db) else {
        throw SpaceError.notFound(id.rawValue)
      }
      try Self.requireMachineNameFree(requested, for: id, group: GroupID(rawValue: row.grp), in: db)
      return try Self.storeMachineName(requested, on: row, in: db)
    }
  }

  // The default a joining box asks for: its hostname, suffixed until free, so a
  // second laptop called "mini" joins as "mini-2" instead of failing the join.
  public func claimMachineName(_ id: MachineID, preferred: String) async throws -> MachineRecord {
    let base = try Self.requireMachineName(preferred)
    return try await writer.write { db in
      guard let row = try MachineRow.where({ $0.id.eq(id.rawValue) }).fetchOne(db) else {
        throw SpaceError.notFound(id.rawValue)
      }
      var candidate = base
      var ordinal = 1
      while true {
        do {
          try Self.requireMachineNameFree(candidate, for: id, group: GroupID(rawValue: row.grp), in: db)
          break
        } catch SpaceError.machineNameTaken {
          ordinal += 1
          let suffix = "_\(ordinal)"
          candidate = String(base.prefix(63 - suffix.count)) + suffix
        }
      }
      return try Self.storeMachineName(candidate, on: row, in: db)
    }
  }

  public func machine(_ id: MachineID) async throws -> MachineRecord? {
    worker.cell(MachineCell.ID(id.rawValue)).record()
  }

  /// The group whose tree holds the machine's notes.
  public func machineGroup(_ id: MachineID) async throws -> GroupID {
    worker.cell(MachineCell.ID(id.rawValue)).record()?.group ?? .shared
  }

  public func machine(account: AccountID) async throws -> MachineRecord? {
    cell.machine(account: account)
  }

  public func machine(named name: String) async throws -> MachineRecord? {
    cell.machine(named: name)
  }

  public func resolveMachine(_ reference: String) async throws -> MachineRecord? {
    if let record = try await machine(MachineID(rawValue: reference)) { return record }
    return try await machine(named: reference)
  }

  // The dial-in oracle: resolves only through the LIVE key row, so kicking the
  // key row is what revokes the machine.
  public func machine(pubkey: String) async throws -> MachineID? {
    guard let key = try await credential(pubkey: pubkey), key.capabilities.contains(.execMachine) else { return nil }
    return try await machine(account: key.account)?.id
  }

  public func machines() async throws -> [MachineRecord] {
    cell.machines()
  }

  /// The machines `group` may use, by the same switch that admits a single
  /// one: the list shows only what it can exec on.
  public func machines(usableFrom group: GroupID) async throws -> [MachineRecord] {
    cell.machines(usableFrom: group)
  }

  /// A machine `group` may not use resolves as no machine at all.
  public func resolveMachine(_ reference: String, usableFrom group: GroupID) async throws -> MachineRecord? {
    guard let record = try await resolveMachine(reference) else { return nil }
    guard try await canUse(record, from: group) else { return nil }
    return record
  }

  /// Whether `group` may use `record`: `owner` is its own group alone;
  /// `reachable` is every group with write in its owner group.
  public func canUse(_ record: MachineRecord, from group: GroupID) async throws -> Bool {
    cell.canUse(record, from: group)
  }

  /// Switches who may use a machine: its own group, or every group that can
  /// reach that one.
  public func setMachineScope(_ id: MachineID, scope: ReachScope) async throws -> MachineRecord {
    try await writer.write { db in
      guard var row = try MachineRow.where({ $0.id.eq(id.rawValue) }).fetchOne(db) else {
        throw SpaceError.notFound(id.rawValue)
      }
      row.scope = scope.rawValue
      try MachineRow.update(row).execute(db)
      return Self.machineRecord(from: row)
    }
  }

  /// Hands the machine to `group`. Its notes live with its current group, so
  /// they move into `group`'s tree in the same transaction and revision; a
  /// note already stored there under the same path gives way to the moved one.
  public func moveMachine(_ id: MachineID, to group: GroupID) async throws -> MachineRecord {
    let notes = try SpacePath(validating: "/_/machines/\(id.rawValue)")
    let mtime = SQLiteDateFormat.string(from: dateGen.now)
    var tries = 0
    while true {
      if let current = worker.cell(MachineCell.ID(id.rawValue)).record()?.group {
        try await documents.checkpoint(under: notes, in: current)
      }
      do {
        return try await blobs.write(
          writer,
          prefetching: { db in
            guard let row = try MachineRow.where({ $0.id.eq(id.rawValue) }).fetchOne(db) else { return [] }
            return try Substrate.descendantHeads(of: notes, group: GroupID(rawValue: row.grp), in: db)
              .compactMap { $0.kind == "file" ? $0.blobHash : nil }
          },
        ) { db, cache in
          guard let row = try MachineRow.where({ $0.id.eq(id.rawValue) }).fetchOne(db) else {
            throw SpaceError.notFound(id.rawValue)
          }
          let from = GroupID(rawValue: row.grp)
          try DocumentRows.requireCommitted(from, under: notes, in: db)
          let movedRow = MachineRow(
            id: row.id, accountID: row.accountID, name: row.name, createdAt: row.createdAt, grp: group.rawValue, scope: row.scope,
          )
          try MachineRow.update(movedRow).execute(db)
          if var member = try MachineV2MemberRow.where({ $0.machineID.eq(id.rawValue) }).fetchOne(db) {
            member.grp = group.rawValue
            try MachineV2MemberRow.update(member).execute(db)
          }
          let record = Self.machineRecord(from: movedRow)
          guard from != group, try Substrate.head(notes, group: from, in: db) != nil else { return record }
          let rev = try Substrate.mintRevision(mtime: mtime, group: group, in: db)
          try Substrate.ensureAncestorDirectories(notes, group: group, rev: rev, mtime: mtime, in: db)
          for node in try Substrate.descendantHeads(of: notes, group: from, in: db).reversed() {
            let path = try SpacePath(validating: node.path)
            if let existing = try Substrate.head(path, group: group, in: db) {
              if existing.kind == "directory", node.kind == "directory" {
                try LiveFS.tombstone(path: node.path, group: from, rev: rev, op: .delete, in: db)
                continue
              }
              let displaced = existing.kind == "directory" ? try Substrate.descendantHeads(of: path, group: group, in: db) : [existing]
              for stale in displaced {
                try LiveFS.remove(stale, group: group, rev: rev, op: .delete, in: db)
              }
            }
            if node.kind == "table" {
              try Tables.reparent(from: path, in: from, to: path, in: group, rev: rev, in: db)
            }
            try LiveFS.tombstone(path: node.path, group: from, rev: rev, op: .delete, in: db)
            try Substrate.appendVersion(group: group, path: node.path, rev: rev, kind: node.kind, blobHash: node.blobHash, op: .write, in: db)
            try Substrate.upsertHead(
              FSHeadRow(
                grp: group.rawValue, path: node.path, parentPath: path.parent.rawValue, kind: node.kind,
                blobHash: node.blobHash, size: node.size, lineCount: node.lineCount, etag: node.etag, rev: rev, mtime: mtime,
              ),
              in: db,
            )
            if node.kind == "file", let hash = node.blobHash {
              try Induction.index(path: path, group: group, content: try cache.blob(of: hash, in: db).content, in: db)
            }
          }
          try self.documents.removed(under: notes, in: from, rev: rev, on: db)
          try self.documents.removed(under: notes, in: group, rev: rev, on: db)
          return record
        }
      } catch is DocumentEdited {
        tries += 1
        if tries == 3 { throw SpaceError.liveBusy(notes.rawValue) }
      }
    }
  }

  func randomSuffix(_ count: Int) -> String {
    randomAlphanumericSuffix(count, rng: rng)
  }

  private static func requireMachine(_ id: MachineID, in db: Database) throws {
    guard try MachineRow.where({ $0.id.eq(id.rawValue) }).fetchOne(db) != nil else {
      throw SpaceError.notFound(id.rawValue)
    }
  }

  private static func requireMachineName(_ raw: String) throws -> String {
    guard let normalized = MachineName.normalized(raw) else { throw SpaceError.invalidMachineName(raw) }
    return normalized
  }

  static func requireMachineNameFree(_ name: String, for id: MachineID, group: GroupID, in db: Database) throws {
    do { try Aliases.claimMachine(name, target: id.rawValue, group: group, in: db) }
    catch AliasError.taken { throw SpaceError.machineNameTaken(name) }
  }

  private static func storeMachineName(_ name: String, on row: MachineRow, in db: Database) throws -> MachineRecord {
    let renamed = MachineRow(
      id: row.id, accountID: row.accountID, name: name, createdAt: row.createdAt, grp: row.grp, scope: row.scope,
    )
    try MachineRow.update(renamed).execute(db)
    try db.execute(sql: "UPDATE accounts SET name = ? WHERE id = ?", arguments: [name, row.accountID])
    return machineRecord(from: renamed)
  }

  static func machineRecord(from row: MachineRow) -> MachineRecord {
    MachineRecord(
      id: MachineID(rawValue: row.id),
      account: AccountID(rawValue: row.accountID),
      name: row.name,
      createdAt: (try? SQLiteDateFormat.date(from: row.createdAt)) ?? Date(timeIntervalSince1970: 0),
      group: GroupID(rawValue: row.grp),
      scope: ReachScope(rawValue: row.scope) ?? .owner,
    )
  }
}
