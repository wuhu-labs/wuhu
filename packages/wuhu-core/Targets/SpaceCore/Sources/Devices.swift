#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import struct MachineContract.MachineID
import SessionDomain
import StructuredQueries
import Wuwei
import WuweiQueries

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
  @Column("owner_account") var ownerAccount: String
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
  public func upsertDevice(pubkey: String, installation: String, kind: String, name: String) async throws -> DeviceRecord {
    guard let kind = DeviceKind(rawValue: kind) else { throw SpaceError.invalidDeviceKind(kind) }
    try Self.checkDeviceName(name)
    guard let key = try await credential(pubkey: pubkey), key.capabilities.contains(.device) else { throw SpaceError.unknownDevice(pubkey) }
    let existing = worker.cell(PersonCell.ID(key.account.rawValue)).device(installation: installation)
    let id: String
    if let existing { id = existing.id }
    else { id = try await allocate(.device, createdBy: key.account.rawValue).name }
    let now = dateGen.now
    return try await worker.call(PersonCell.ID(key.account.rawValue)) { try $0.upsertDevice(id: id, pubkey: pubkey, installation: installation, kind: kind, name: name, at: now) }
  }

  static func checkDeviceName(_ name: String) throws {
    if let problem = DeviceName.problem(name) { throw SpaceError.invalidDeviceName("device name \(name) \(problem)") }
  }

  public func devices() async throws -> [DeviceRecord] { cell.devices() }
  public func device(id: String) async throws -> DeviceRecord? { cell.device(id: id) }
  public func device(pubkey: String) async throws -> DeviceRecord? { cell.device(pubkey: pubkey) }

  public func annotateDevice(_ id: String, name: String?, machine: MachineID?) async throws -> DeviceRecord {
    if let name { try Self.checkDeviceName(name) }
    guard let device = cell.device(id: id) else { throw SpaceError.unknownDevice(id) }
    return try await worker.call(PersonCell.ID(device.account.rawValue)) { try $0.annotateDevice(id, name: name, machine: machine) }
  }

  @discardableResult
  public func issueDeviceCommand(device: String, payload: String, issuedBy: String) async throws -> Int64 {
    guard let row = cell.device(id: device) else { throw SpaceError.unknownDevice(device) }
    let now = dateGen.now
    return try await worker.call(PersonCell.ID(row.account.rawValue)) { try $0.issueDeviceCommand(device, payload: payload, issuedBy: issuedBy, at: now) }
  }

  public func issueDeviceCommand(device: String, payload: String, issuedBy session: SessionID, answering callID: ToolCallID) async throws -> ToolResultPayload {
    let n = try await issueDeviceCommand(device: device, payload: payload, issuedBy: session.rawValue)
    return .manipulateUI(.init(device: device, n: n))
  }

  public func deviceNames() async throws -> [String: String] { Dictionary(uniqueKeysWithValues: cell.devices().map { ($0.id, $0.name) }) }
}

extension DeviceRow {
  var record: DeviceRecord {
    DeviceRecord(id: id, account: AccountID(rawValue: accountID), pubkey: pubkey, installation: installation, kind: DeviceKind(rawValue: kind)!, name: name, machine: machineID.map(MachineID.init(rawValue:)), createdAt: try! SQLiteDateFormat.date(from: createdAt), lastSeenAt: try! SQLiteDateFormat.date(from: lastSeenAt))
  }
}

extension SpaceCell {
  func devices() -> [DeviceRecord] { db.rows(DeviceRow.order { $0.id }).map(\.record) }
  func device(id: String) -> DeviceRecord? { db.rows(DeviceRow.where { $0.id.eq(id) }).first?.record }
  func device(pubkey: String) -> DeviceRecord? { db.rows(DeviceRow.where { $0.pubkey.eq(pubkey) }).first?.record }
}

extension PersonCell {
  func device(installation: String) -> DeviceRecord? { db.rows(DeviceRow.where { $0.accountID.eq(id.key) && $0.installation.eq(installation) }).first?.record }

  mutating func upsertDevice(id allocated: String, pubkey: String, installation: String, kind: DeviceKind, name: String, at now: Date) throws -> DeviceRecord {
    let existing = db.rows(DeviceRow.where { $0.accountID.eq(id.key) && $0.installation.eq(installation) }).first
    let holder = ctx.cell(SpaceCell.ID("space")).device(pubkey: pubkey)
    guard holder == nil || holder?.id == existing?.id else { throw SpaceError.alreadyExists(pubkey) }
    let stamp = SQLiteDateFormat.string(from: now)
    var row = existing ?? DeviceRow(id: allocated, accountID: id.key, pubkey: pubkey, installation: installation, kind: kind.rawValue, name: name, machineID: nil, createdAt: stamp, lastSeenAt: stamp)
    row.pubkey = pubkey
    row.kind = kind.rawValue
    row.name = name
    row.lastSeenAt = stamp
    try db.execute(DeviceRow.upsert { row })
    return row.record
  }

  mutating func annotateDevice(_ device: String, name: String?, machine: MachineID?) throws -> DeviceRecord {
    guard var row = db.rows(DeviceRow.where { $0.accountID.eq(id.key) && $0.id.eq(device) }).first else { throw SpaceError.unknownDevice(device) }
    if let name { row.name = name }
    if let machine {
      guard !db.rows(MachineRow.where { $0.id.eq(machine.rawValue) }).isEmpty else { throw SpaceError.notFound(machine.rawValue) }
      row.machineID = machine.rawValue
    }
    try db.execute(DeviceRow.upsert { row })
    return row.record
  }

  mutating func issueDeviceCommand(_ device: String, payload: String, issuedBy: String, at now: Date) throws -> Int64 {
    guard !db.rows(DeviceRow.where { $0.accountID.eq(id.key) && $0.id.eq(device) }).isEmpty else { throw SpaceError.unknownDevice(device) }
    try db.execute(DeviceCommandRow.insert { DeviceCommandRow.Draft(deviceID: device, ownerAccount: id.key, payload: payload, issuedBy: issuedBy, createdAt: SQLiteDateFormat.string(from: now)) })
    return db.rows(#sql("SELECT last_insert_rowid()", as: Int64.self)).first!
  }
}

/// A device name is shown on one line inside a message header.
enum GroupName {
  static func checked(_ raw: String) throws -> String {
    let name = raw.trimmingCharacters(in: .whitespaces)
    if name.isEmpty { throw SpaceError.invalidGroupName("a group name may not be empty") }
    if let problem = DeviceName.problem(name) { throw SpaceError.invalidGroupName("group name \(name) \(problem)") }
    return name
  }
}

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
