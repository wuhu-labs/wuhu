import Foundation
import GRDB
import struct MachineContract.ExecID
import struct MachineContract.MachineID
import struct SessionDomain.ToolCallID
import struct SpaceContract.GroupID
import SpaceFS
import StructuredQueries
import StructuredQueriesSQLite

public struct MachineRecord: Equatable, Sendable {
  public let id: MachineID
  public let account: AccountID
  public let name: String?
  public let createdAt: Date
  /// The group the machine belongs to: groups that read it may exec on it.
  public let group: GroupID
}

// Underscore is excluded so a name can never satisfy MachineID.isValid, which
// is what lets one route parameter carry either.
public enum MachineName {
  public static func normalized(_ raw: String) -> String? {
    normalizedLabel(raw, allowing: ["-", "."], length: 1 ... 63)
  }
}

public enum ExecTerminalState: Equatable, Sendable {
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

public struct ExecRecord: Equatable, Sendable {
  public let id: ExecID
  public let machine: MachineID
  public let streamID: Int
  public let command: String
  public let caller: String?
  public let toolCallID: ToolCallID?
  public let startedAt: Date
  public let terminal: ExecTerminalState?
  public let killDelivered: Bool
  /// The group the exec is homed in: groups that read it may see and join it.
  public let group: GroupID
}

public struct ExecClaim: Equatable, Sendable {
  public let record: ExecRecord
  public let rejoined: Bool
}

// The execs a run_script execution owned when the server that ran it went
// away; `live` are the ones the registry still holds live.
public struct ScriptExecOwner: Equatable, Sendable {
  public let script: String
  public let session: String
  public let live: [ExecID]
}

extension Space {
  /// A machine enrolled by a person joins that person's group; `shared` holds
  /// every machine from before groups.
  public func addMachine(name: String?, group: GroupID = .shared) async throws -> MachineRecord {
    let requested = try name.map { try Self.requireMachineName($0) }
    let id = MachineID(rawValue: "mc_" + randomSuffix(MachineID.suffixLength))
    let account = AccountID(rawValue: AccountID.prefix + randomSuffix(AccountID.suffixLength))
    let createdAt = dateGen.now
    let stored = SQLiteDateFormat.string(from: createdAt)
    try await writer.write { db in
      if let requested { try Self.requireMachineNameFree(requested, besides: nil, in: db) }
      try db.execute(
        sql: "INSERT INTO accounts (id, kind, name, created_at) VALUES (?, ?, ?, ?)",
        arguments: [account.rawValue, AccountKind.machine.rawValue, requested, stored],
      )
      try MachineRow.insert {
        MachineRow(id: id.rawValue, accountID: account.rawValue, name: requested, createdAt: stored, grp: group.rawValue)
      }.execute(db)
    }
    return MachineRecord(id: id, account: account, name: requested, createdAt: createdAt, group: group)
  }

  public func renameMachine(_ id: MachineID, name: String) async throws -> MachineRecord {
    let requested = try Self.requireMachineName(name)
    return try await writer.write { db in
      guard let row = try MachineRow.where({ $0.id.eq(id.rawValue) }).fetchOne(db) else {
        throw SpaceError.notFound(id.rawValue)
      }
      try Self.requireMachineNameFree(requested, besides: id, in: db)
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
      while try Self.machineNameHolder(candidate, in: db).map({ $0 != id.rawValue }) == true {
        ordinal += 1
        candidate = String("\(base)-\(ordinal)".prefix(63))
      }
      return try Self.storeMachineName(candidate, on: row, in: db)
    }
  }

  public func machine(_ id: MachineID) async throws -> MachineRecord? {
    try await writer.read { db in
      try MachineRow.where { $0.id.eq(id.rawValue) }.fetchOne(db).map(Self.machineRecord(from:))
    }
  }

  /// The group whose tree holds the machine's notes.
  public func machineGroup(_ id: MachineID) async throws -> GroupID {
    try await writer.read { db in
      try MachineRow.where { $0.id.eq(id.rawValue) }.fetchOne(db).map { GroupID(rawValue: $0.grp) } ?? .shared
    }
  }

  public func machine(account: AccountID) async throws -> MachineRecord? {
    try await writer.read { db in
      try MachineRow.where { $0.accountID.eq(account.rawValue) }.fetchOne(db).map(Self.machineRecord(from:))
    }
  }

  public func machine(named name: String) async throws -> MachineRecord? {
    let lowered = name.lowercased()
    return try await writer.read { db in
      try MachineRow.where { $0.name.lower().eq(lowered) }.fetchOne(db).map(Self.machineRecord(from:))
    }
  }

  public func resolveMachine(_ reference: String) async throws -> MachineRecord? {
    if MachineID.isValid(reference) { return try await machine(MachineID(rawValue: reference)) }
    return try await machine(named: reference)
  }

  // The dial-in oracle: resolves only through the LIVE key row, so kicking the
  // key row is what revokes the machine.
  public func machine(pubkey: String) async throws -> MachineID? {
    guard let key = try await credential(pubkey: pubkey), key.capabilities.contains(.execMachine) else { return nil }
    return try await machine(account: key.account)?.id
  }

  public func machines() async throws -> [MachineRecord] {
    try await writer.read { db in
      try MachineRow.order { $0.id }.fetchAll(db).map(Self.machineRecord(from:))
    }
  }

  /// The machines `group` may exec on: those whose group it reads.
  public func machines(usableFrom group: GroupID) async throws -> [MachineRecord] {
    let readable = try await reads(group)
    return try await machines().filter { readable.contains($0.group) }
  }

  /// A machine `group` may not use resolves as no machine at all.
  public func resolveMachine(_ reference: String, usableFrom group: GroupID) async throws -> MachineRecord? {
    guard let record = try await resolveMachine(reference), try await reads(group).contains(record.group) else { return nil }
    return record
  }

  /// Hands the machine to `group`. Its notes live with its current group, so
  /// they move into `group`'s tree in the same transaction and revision; a
  /// note already stored there under the same path gives way to the moved one.
  public func moveMachine(_ id: MachineID, to group: GroupID) async throws -> MachineRecord {
    let notes = try SpacePath(validating: "/_/machines/\(id.rawValue)")
    let mtime = SQLiteDateFormat.string(from: dateGen.now)
    let (record, from, rev, moved): (MachineRecord, GroupID, Int64?, [(path: String, entry: Entry.Kind)]) = try await blobs.write(
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
      let movedRow = MachineRow(id: row.id, accountID: row.accountID, name: row.name, createdAt: row.createdAt, grp: group.rawValue)
      try MachineRow.update(movedRow).execute(db)
      let record = Self.machineRecord(from: movedRow)
      guard from != group, try Substrate.head(notes, group: from, in: db) != nil else { return (record, from, nil, []) }
      let rev = try Substrate.mintRevision(mtime: mtime, group: group, in: db)
      try Substrate.ensureAncestorDirectories(notes, group: group, rev: rev, mtime: mtime, in: db)
      var moved: [(path: String, entry: Entry.Kind)] = []
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
        moved.append((node.path, Substrate.entryKind(node.kind)))
      }
      return (record, from, rev, moved)
    }
    if let rev {
      for note in moved {
        broadcast.emit(MutationEvent(group: from, path: note.path, rev: Int(rev), kind: .delete, entry: nil))
        broadcast.emit(MutationEvent(group: group, path: note.path, rev: Int(rev), kind: .write, entry: note.entry))
      }
    }
    return record
  }

  /// `group` homes the exec where its minter acts; nil homes it by `execGroup`.
  public func mintExec(machine: MachineID, caller: String? = nil, group: GroupID? = nil) async throws -> ExecRecord {
    let id = ExecID(rawValue: "ex_" + randomSuffix(ExecID.suffixLength))
    let startedAt = dateGen.now
    let started = SQLiteDateFormat.string(from: startedAt)
    let (streamID, home) = try await writer.write { db in
      let home = try group?.rawValue ?? Self.execGroup(machine, caller: caller, in: db)
      return (try Self.insertExec(id, machine: machine, caller: caller, toolCallID: nil, startedAt: started, group: home, in: db), home)
    }
    return ExecRecord(
      id: id,
      machine: machine,
      streamID: Int(streamID),
      command: "",
      caller: caller,
      toolCallID: nil,
      startedAt: startedAt,
      terminal: nil,
      killDelivered: false,
      group: GroupID(rawValue: home),
    )
  }

  // The owner row commits with the exec row, so no process exists that a boot
  // after a crash could not attribute to its script.
  public func mintScriptExec(machine: MachineID, session: String, script: String) async throws -> ExecRecord {
    let id = ExecID(rawValue: "ex_" + randomSuffix(ExecID.suffixLength))
    let startedAt = dateGen.now
    let started = SQLiteDateFormat.string(from: startedAt)
    let (streamID, group) = try await writer.write { db in
      let group = try Self.execGroup(machine, caller: session, in: db)
      let streamID = try Self.insertExec(id, machine: machine, caller: session, toolCallID: nil, startedAt: started, group: group, in: db)
      try ScriptExecRow.insert {
        ScriptExecRow(execID: id.rawValue, scriptID: script, sessionID: session, grp: group)
      }.execute(db)
      return (streamID, group)
    }
    return ExecRecord(
      id: id,
      machine: machine,
      streamID: Int(streamID),
      command: "",
      caller: session,
      toolCallID: nil,
      startedAt: startedAt,
      terminal: nil,
      killDelivered: false,
      group: GroupID(rawValue: group),
    )
  }

  public func releaseScriptExecs(script: String) async throws {
    try await writer.write { db in
      try ScriptExecRow.where { $0.scriptID.eq(script) }.delete().execute(db)
    }
  }

  // Owner rows outlive their script only when the server running it died, so
  // at boot every row left is a script that restart killed. Taking them clears
  // them: each script is reported once.
  public func takeScriptExecOwners() async throws -> [ScriptExecOwner] {
    try await writer.write { db in
      let rows = try ScriptExecRow.order { ($0.sessionID, $0.scriptID, $0.execID) }.fetchAll(db)
      guard !rows.isEmpty else { return [] }
      let live = try Set(String.fetchAll(
        db,
        sql: "SELECT e.id FROM machine_execs e JOIN script_execs s ON s.exec_id = e.id WHERE e.terminal_state IS NULL",
      ))
      try ScriptExecRow.delete().execute(db)
      var owners: [ScriptExecOwner] = []
      for row in rows {
        let exec = live.contains(row.execID) ? [ExecID(rawValue: row.execID)] : []
        if let last = owners.last, last.script == row.scriptID, last.session == row.sessionID {
          owners[owners.count - 1] = ScriptExecOwner(script: last.script, session: last.session, live: last.live + exec)
        } else {
          owners.append(ScriptExecOwner(script: row.scriptID, session: row.sessionID, live: exec))
        }
      }
      return owners
    }
  }

  // Mark-started-before-spawn: the row exists before any exec-start frame is
  // sent, so a crash-retry with the same kernel tool call id rejoins this exec
  // instead of spawning a second process.
  public func claimExec(machine: MachineID, caller: String, toolCallID: ToolCallID) async throws -> ExecClaim {
    let id = ExecID(rawValue: "ex_" + randomSuffix(ExecID.suffixLength))
    let started = SQLiteDateFormat.string(from: dateGen.now)
    return try await writer.write { db in
      if let existing = try Row.fetchOne(
        db,
        sql: "SELECT * FROM machine_execs WHERE caller = ? AND tool_call_id = ?",
        arguments: [caller, toolCallID.rawValue],
      ) {
        return ExecClaim(record: Self.execRecord(from: existing), rejoined: true)
      }
      _ = try Self.insertExec(
        id, machine: machine, caller: caller, toolCallID: toolCallID, startedAt: started,
        group: Self.execGroup(machine, caller: caller, in: db), in: db,
      )
      guard let row = try Row.fetchOne(db, sql: "SELECT * FROM machine_execs WHERE id = ?", arguments: [id.rawValue]) else {
        throw SpaceError.notFound(id.rawValue)
      }
      return ExecClaim(record: Self.execRecord(from: row), rejoined: false)
    }
  }

  // An exec is homed in its calling session's group, else in its machine's.
  private static func execGroup(_ machine: MachineID, caller: String?, in db: Database) throws -> String {
    if let caller, let group = try String.fetchOne(db, sql: "SELECT grp FROM sessions WHERE id = ?", arguments: [caller]) {
      return group
    }
    return try String.fetchOne(db, sql: "SELECT grp FROM machines WHERE id = ?", arguments: [machine.rawValue]) ?? GroupID.shared.rawValue
  }

  private static func insertExec(
    _ id: ExecID,
    machine: MachineID,
    caller: String?,
    toolCallID: ToolCallID?,
    startedAt: String,
    group: String,
    in db: Database,
  ) throws -> Int64 {
    try requireMachine(machine, in: db)
    let streamID = (try Int64.fetchOne(
      db,
      sql: "SELECT COALESCE(MAX(stream_id), 0) + 1 FROM machine_execs WHERE machine_id = ?",
      arguments: [machine.rawValue],
    )) ?? 1
    try db.execute(
      sql: """
      INSERT INTO machine_execs (id, machine_id, stream_id, command, caller, tool_call_id, started_at, grp)
      VALUES (?, ?, ?, '', ?, ?, ?, ?)
      """,
      arguments: [id.rawValue, machine.rawValue, streamID, caller, toolCallID?.rawValue, startedAt, group],
    )
    return streamID
  }

  public func recordExecCommand(_ id: ExecID, command: String) async throws {
    try await writer.write { db in
      try db.execute(
        sql: "UPDATE machine_execs SET command = ? WHERE id = ? AND command = ''",
        arguments: [command, id.rawValue],
      )
    }
  }

  public func execRecord(_ id: ExecID) async throws -> ExecRecord? {
    try await writer.read { db in
      try Row.fetchOne(db, sql: "SELECT * FROM machine_execs WHERE id = ?", arguments: [id.rawValue])
        .map(Self.execRecord(from:))
    }
  }

  public func execRecord(caller: String, toolCallID: ToolCallID) async throws -> ExecRecord? {
    try await writer.read { db in
      try Row.fetchOne(
        db,
        sql: "SELECT * FROM machine_execs WHERE caller = ? AND tool_call_id = ?",
        arguments: [caller, toolCallID.rawValue],
      ).map(Self.execRecord(from:))
    }
  }

  public func execRecord(machine: MachineID, streamID: Int) async throws -> ExecRecord? {
    try await writer.read { db in
      try Row.fetchOne(
        db,
        sql: "SELECT * FROM machine_execs WHERE machine_id = ? AND stream_id = ?",
        arguments: [machine.rawValue, streamID],
      ).map(Self.execRecord(from:))
    }
  }

  public func liveExecs() async throws -> [ExecRecord] {
    try await writer.read { db in
      try Row.fetchAll(
        db,
        sql: "SELECT * FROM machine_execs WHERE terminal_state IS NULL ORDER BY started_at, id",
      ).map(Self.execRecord(from:))
    }
  }

  // Exit states settle cancelled and machine-lost rows (they can still resolve
  // to the real exit once it replays) but never a reaped one: the reap verdict
  // is the honest story a rejoining retry must see. Cancel, reap, and
  // machine-lost only claim rows that are still live.
  public func finishExec(_ id: ExecID, _ state: ExecTerminalState) async throws {
    try await writer.write { db in
      switch state {
      case .exited, .signaled:
        try db.execute(
          sql: "UPDATE machine_execs SET terminal_state = ? WHERE id = ? AND (terminal_state IS NULL OR terminal_state IN ('cancelled', 'machine-lost'))",
          arguments: [state.stored, id.rawValue],
        )
      case .cancelled, .reaped, .machineLost:
        try db.execute(
          sql: "UPDATE machine_execs SET terminal_state = ? WHERE id = ? AND terminal_state IS NULL",
          arguments: [state.stored, id.rawValue],
        )
      }
    }
  }

  // A machine-lost exec may still be running on a box that only dropped off
  // the network, so it is a candidate too; the hub skips the ones a connected
  // caller is about to resume.
  public func pendingKills(machine: MachineID) async throws -> [ExecRecord] {
    try await writer.read { db in
      try Row.fetchAll(
        db,
        sql: "SELECT * FROM machine_execs WHERE machine_id = ? AND terminal_state IN ('cancelled', 'reaped', 'machine-lost') AND kill_delivered = 0",
        arguments: [machine.rawValue],
      ).map(Self.execRecord(from:))
    }
  }

  public func markKillDelivered(_ id: ExecID) async throws {
    try await writer.write { db in
      try db.execute(sql: "UPDATE machine_execs SET kill_delivered = 1 WHERE id = ?", arguments: [id.rawValue])
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

  // Uniqueness is a lookup inside the write transaction, never a unique index:
  // an index would fail Space.open on a legacy space holding two same-named
  // machines.
  private static func requireMachineNameFree(_ name: String, besides id: MachineID?, in db: Database) throws {
    guard let holder = try machineNameHolder(name, in: db), holder != id?.rawValue else { return }
    throw SpaceError.machineNameTaken(name)
  }

  private static func storeMachineName(_ name: String, on row: MachineRow, in db: Database) throws -> MachineRecord {
    let renamed = MachineRow(id: row.id, accountID: row.accountID, name: name, createdAt: row.createdAt, grp: row.grp)
    try MachineRow.update(renamed).execute(db)
    try db.execute(sql: "UPDATE accounts SET name = ? WHERE id = ?", arguments: [name, row.accountID])
    return machineRecord(from: renamed)
  }

  private static func machineNameHolder(_ name: String, in db: Database) throws -> String? {
    try MachineRow.where { $0.name.lower().eq(name) }.select { $0.id }.fetchOne(db)
  }

  private static func machineRecord(from row: MachineRow) -> MachineRecord {
    MachineRecord(
      id: MachineID(rawValue: row.id),
      account: AccountID(rawValue: row.accountID),
      name: row.name,
      createdAt: (try? SQLiteDateFormat.date(from: row.createdAt)) ?? Date(timeIntervalSince1970: 0),
      group: GroupID(rawValue: row.grp),
    )
  }

  private static func execRecord(from row: Row) -> ExecRecord {
    ExecRecord(
      id: ExecID(rawValue: row["id"]),
      machine: MachineID(rawValue: row["machine_id"]),
      streamID: Int(row["stream_id"] as Int64),
      command: row["command"],
      caller: row["caller"],
      toolCallID: (row["tool_call_id"] as String?).map(ToolCallID.init(rawValue:)),
      startedAt: (try? SQLiteDateFormat.date(from: row["started_at"])) ?? Date(timeIntervalSince1970: 0),
      terminal: (row["terminal_state"] as String?).flatMap(ExecTerminalState.init(stored:)),
      killDelivered: (row["kill_delivered"] as Int64) != 0,
      group: GroupID(rawValue: row["grp"] as String? ?? GroupID.shared.rawValue),
    )
  }
}
