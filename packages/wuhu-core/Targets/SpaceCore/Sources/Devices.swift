import Foundation
import GRDB
import struct MachineContract.MachineID
import SessionDomain
import StructuredQueries
import StructuredQueriesSQLite

let deviceSchemaSQL = """
CREATE TABLE IF NOT EXISTS "devices" (
  "id" TEXT NOT NULL PRIMARY KEY,
  "account_id" TEXT NOT NULL REFERENCES "accounts" ("id"),
  "pubkey" TEXT NOT NULL UNIQUE,
  "installation" TEXT NOT NULL,
  "kind" TEXT NOT NULL CHECK ("kind" IN ('phone', 'pad', 'mac', 'vision', 'web')),
  "name" TEXT NOT NULL,
  "machine_id" TEXT REFERENCES "machines" ("id"),
  "created_at" TEXT NOT NULL,
  "last_seen_at" TEXT NOT NULL
);
CREATE UNIQUE INDEX IF NOT EXISTS "devices_by_installation" ON "devices" ("account_id", "installation");
CREATE TABLE IF NOT EXISTS "device_commands" (
  "n" INTEGER PRIMARY KEY AUTOINCREMENT,
  "device_id" TEXT NOT NULL REFERENCES "devices" ("id"),
  "payload" TEXT NOT NULL,
  "issued_by" TEXT NOT NULL,
  "created_at" TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS "device_commands_by_device" ON "device_commands" ("device_id", "n");
CREATE TABLE IF NOT EXISTS "message_devices" (
  "message_id" TEXT NOT NULL PRIMARY KEY,
  "device_id" TEXT NOT NULL REFERENCES "devices" ("id")
);
"""

@Table("devices")
struct DeviceRow {
  @Column("id", primaryKey: true) var id: String
  @Column("account_id") var accountID: String
  @Column("pubkey") var pubkey: String
  @Column("installation") var installation: String
  @Column("kind") var kind: String
  @Column("name") var name: String
  @Column("machine_id") var machineID: String?
  @Column("created_at") var createdAt: String
  @Column("last_seen_at") var lastSeenAt: String
}

@Table("device_commands")
struct DeviceCommandRow {
  @Column("n", primaryKey: true) var n: Int64
  @Column("device_id") var deviceID: String
  @Column("payload") var payload: String
  @Column("issued_by") var issuedBy: String
  @Column("created_at") var createdAt: String
}

@Table("message_devices")
struct MessageDeviceRow {
  @Column("message_id", primaryKey: true) var messageID: String
  @Column("device_id") var deviceID: String
}

public enum DeviceKind: String, Hashable, Sendable, CaseIterable {
  case phone
  case pad
  case mac
  case vision
  case web
}

public struct DeviceRecord: Equatable, Sendable {
  public let id: String
  public let account: AccountID
  public let pubkey: String
  public let installation: String
  public let kind: DeviceKind
  public let name: String
  public let machine: MachineID?
  public let createdAt: Date
  public let lastSeenAt: Date
}

extension Space {
  // Identity is (account, installation): the app mints the installation once
  // per install, so a re-enrolled device adopts its own row with a new key
  // instead of orphaning it.
  public func upsertDevice(
    pubkey: String,
    installation: String,
    kind: String,
    name: String,
  ) async throws -> DeviceRecord {
    guard let kind = DeviceKind(rawValue: kind) else { throw SpaceError.invalidDeviceKind(kind) }
    try Self.checkDeviceName(name)
    guard let key = try await credential(pubkey: pubkey), key.capabilities.contains(.device) else {
      throw SpaceError.unknownDevice(pubkey)
    }
    let now = dateGen.now
    let stamp = SQLiteDateFormat.string(from: now)
    let minted = Allocations.mintSecretCandidate(rng)
    let row = try await writer.write { db -> DeviceRow in
      let existing = try DeviceRow
        .where { $0.accountID.eq(key.account.rawValue) && $0.installation.eq(installation) }
        .fetchOne(db)
      let holder = try DeviceRow.where { $0.pubkey.eq(pubkey) }.fetchOne(db)
      guard holder == nil || holder?.id == existing?.id else { throw SpaceError.alreadyExists(pubkey) }
      var row: DeviceRow
      if let existing {
        row = existing
        row.pubkey = pubkey
        row.kind = kind.rawValue
        row.name = name
      } else {
        let allocated = try Allocations.draw(
          .device, createdBy: key.account.rawValue, created: stamp, minted: minted, in: db,
        )
        row = DeviceRow(
          id: allocated.name,
          accountID: key.account.rawValue,
          pubkey: pubkey,
          installation: installation,
          kind: kind.rawValue,
          name: name,
          machineID: nil,
          createdAt: stamp,
          lastSeenAt: stamp,
        )
      }
      row.lastSeenAt = stamp
      try DeviceRow.upsert { row }.execute(db)
      return row
    }
    return Self.device(from: row)
  }

  static func checkDeviceName(_ name: String) throws {
    if let problem = DeviceName.problem(name) { throw SpaceError.invalidDeviceName("device name \(name) \(problem)") }
  }

  public func devices() async throws -> [DeviceRecord] {
    try await writer.read { db in
      try DeviceRow.order { $0.id }.fetchAll(db).map(Self.device(from:))
    }
  }

  public func device(id: String) async throws -> DeviceRecord? {
    try await writer.read { db in
      try DeviceRow.where { $0.id.eq(id) }.fetchOne(db).map(Self.device(from:))
    }
  }

  public func device(pubkey: String) async throws -> DeviceRecord? {
    try await writer.read { db in
      try DeviceRow.where { $0.pubkey.eq(pubkey) }.fetchOne(db).map(Self.device(from:))
    }
  }

  public func annotateDevice(
    _ id: String,
    name: String?,
    machine: MachineID?,
  ) async throws -> DeviceRecord {
    if let name { try Self.checkDeviceName(name) }
    let row = try await writer.write { db -> DeviceRow in
      let found = try DeviceRow.where { $0.id.eq(id) }.fetchOne(db)
      guard var row = found else { throw SpaceError.unknownDevice(id) }
      if let name { row.name = name }
      if let machine {
        let known = try MachineRow.where { $0.id.eq(machine.rawValue) }.fetchOne(db)
        guard known != nil else { throw SpaceError.notFound(machine.rawValue) }
        row.machineID = machine.rawValue
      }
      try DeviceRow.upsert { row }.execute(db)
      return row
    }
    return Self.device(from: row)
  }

  // The payload is the app's vocabulary, not the server's: it is stored and
  // handed back verbatim, so a new verb needs no server change.
  @discardableResult
  public func issueDeviceCommand(device: String, payload: String, issuedBy: String) async throws -> Int64 {
    let stamp = SQLiteDateFormat.string(from: dateGen.now)
    return try await writer.write { db in
      try Self.insertDeviceCommand(device, payload: payload, issuedBy: issuedBy, at: stamp, in: db)
    }
  }

  // The command as a tool call's effect: the call's answer is looked up and
  // recorded in the write that issues it, so a call already answered (an
  // earlier run, or an overlapping twin of this one) gets that answer and
  // the device is driven once.
  public func issueDeviceCommand(
    device: String,
    payload: String,
    issuedBy session: SessionID,
    answering callID: ToolCallID,
  ) async throws -> ToolResultPayload {
    let stamp = SQLiteDateFormat.string(from: dateGen.now)
    return try await writer.write { db in
      if let recorded = try Sessions.receipt(session.rawValue, toolCallID: callID.rawValue, in: db) { return recorded }
      let n = try Self.insertDeviceCommand(device, payload: payload, issuedBy: session.rawValue, at: stamp, in: db)
      let receipt = ToolReceipt(session: session, callID: callID, payload: .manipulateUI(.init(device: device, n: n)))
      try receipt.record(now: stamp, in: db)
      return receipt.payload
    }
  }

  private static func insertDeviceCommand(_ device: String, payload: String, issuedBy: String, at stamp: String, in db: Database) throws -> Int64 {
    let known = try DeviceRow.where { $0.id.eq(device) }.fetchOne(db)
    guard known != nil else { throw SpaceError.unknownDevice(device) }
    try db.execute(
      sql: "INSERT INTO device_commands (device_id, payload, issued_by, created_at) VALUES (?, ?, ?, ?)",
      arguments: [device, payload, issuedBy, stamp],
    )
    return db.lastInsertedRowID
  }

  public func deviceNames() async throws -> [String: String] {
    Dictionary(uniqueKeysWithValues: try await devices().map { ($0.id, $0.name) })
  }

  private static func device(from row: DeviceRow) -> DeviceRecord {
    DeviceRecord(
      id: row.id,
      account: AccountID(rawValue: row.accountID),
      pubkey: row.pubkey,
      installation: row.installation,
      kind: DeviceKind(rawValue: row.kind)!,
      name: row.name,
      machine: row.machineID.map { MachineID(rawValue: $0) },
      createdAt: (try? SQLiteDateFormat.date(from: row.createdAt)) ?? Date(timeIntervalSince1970: 0),
      lastSeenAt: (try? SQLiteDateFormat.date(from: row.lastSeenAt)) ?? Date(timeIntervalSince1970: 0),
    )
  }
}

/// A device name is shown on one line inside a message header.
enum DeviceName {
  static let maxCharacters = 64

  static func problem(_ name: String) -> String? {
    if name.count > maxCharacters { return "is \(name.count) characters, at most \(maxCharacters)" }
    if name.contains(where: \.isNewline) || name.unicodeScalars.contains(where: { $0.properties.generalCategory == .control }) {
      return "may not contain control characters or line breaks"
    }
    if name.contains(where: { "<>&".contains($0) }) { return "may not contain <, > or &" }
    return nil
  }
}
