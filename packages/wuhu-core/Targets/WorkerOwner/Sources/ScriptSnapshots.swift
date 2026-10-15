#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import enum JSONValue.JSONValue
import struct MachineContract.ExecID
import struct MachineContract.MachineID
import struct OrderedCollections.OrderedDictionary
import struct SessionDomain.SessionID
import struct SessionTools.ScriptModuleSnapshot
import struct SpaceContract.GroupID
import struct SpaceCore.AccountID
import enum SpaceCore.Cell
import struct SpaceCore.MachineRecord
import struct SpaceCore.Principal
import struct SpaceCore.Rev
import enum SpaceCore.RowEdit
import struct SpaceCore.Rows
import struct SpaceCore.ScriptExecOwner
import struct SpaceTools.FileBytes
import struct SpaceTools.FileVersion
import struct WorkerProtocol.WorkerProtocolError

struct PrincipalSnapshot: Codable, Sendable {
  let session: SessionID
  let group: GroupID
  init(_ principal: Principal) throws {
    guard case let .session(session) = principal.actor else { throw WorkerProtocolError(.invalidMessage, message: "Script principal must be a session") }
    self.session = session; group = principal.group
  }

  var value: Principal { .init(actor: .session(session), group: group) }
}

struct ModuleSnapshot: Codable, Sendable {
  let revision: Int
  let acting: GroupID
  let readable: Set<GroupID>
  init(_ snapshot: ScriptModuleSnapshot) { revision = snapshot.revision.value; acting = snapshot.acting; readable = snapshot.readable }
  var value: ScriptModuleSnapshot { .init(revision: Rev(revision), acting: acting, readable: readable) }
}

struct FileBytesSnapshot: Codable, Sendable {
  let token: String
  let rev: Int?
  let data: Data
  init(_ file: FileBytes) { token = file.token; rev = file.rev; data = file.data }
  var value: FileBytes { .init(token: token, rev: rev, data: data) }
}

struct FileVersionSnapshot: Codable, Sendable {
  let token: String
  let rev: Int?
  init(_ file: FileVersion) { token = file.token; rev = file.rev }
  var value: FileVersion { .init(token: token, rev: rev) }
}

struct MachineSnapshot: Codable, Sendable {
  let id: MachineID
  let account: String
  let name: String?
  let createdAt: Date
  let group: GroupID
  init(_ machine: MachineRecord) { id = machine.id; account = machine.account.rawValue; name = machine.name; createdAt = machine.createdAt; group = machine.group }
  var value: MachineRecord { .init(id: id, account: AccountID(rawValue: account), name: name, createdAt: createdAt, group: group) }
}

struct ScriptExecOwnerSnapshot: Codable, Sendable {
  let script: String
  let session: String
  let live: [ExecID]
  init(_ owner: ScriptExecOwner) { script = owner.script; session = owner.session; live = owner.live }
  var value: ScriptExecOwner { .init(script: script, session: session, live: live) }
}

struct CellSnapshot: Codable, Sendable {
  let kind: String
  let integer: Int64?
  let real: Double?
  let text: String?
  let blob: Data?
  init(_ cell: Cell) {
    switch cell {
    case .null: kind = "null"; integer = nil; real = nil; text = nil; blob = nil
    case let .integer(value): kind = "integer"; integer = value; real = nil; text = nil; blob = nil
    case let .real(value): kind = "real"; integer = nil; real = value; text = nil; blob = nil
    case let .text(value): kind = "text"; integer = nil; real = nil; text = value; blob = nil
    case let .blob(value): kind = "blob"; integer = nil; real = nil; text = nil; blob = Data(value)
    }
  }

  func value() throws -> Cell {
    switch kind {
    case "null" where integer == nil && real == nil && text == nil && blob == nil: return .null
    case "integer" where real == nil && text == nil && blob == nil: if let integer { return .integer(integer) }
    case "real" where integer == nil && text == nil && blob == nil: if let real { return .real(real) }
    case "text" where integer == nil && real == nil && blob == nil: if let text { return .text(text) }
    case "blob" where integer == nil && real == nil && text == nil: if let blob { return .blob(Array(blob)) }
    default: break
    }
    throw WorkerProtocolError(.invalidMessage, message: "Invalid query cell snapshot")
  }
}

struct RowsSnapshot: Codable, Sendable {
  let columns: [String]
  let decltypes: [String?]
  let rows: [[CellSnapshot]]
  init(_ result: Rows) { columns = result.columns; decltypes = result.decltypes; rows = result.rows.map { $0.map(CellSnapshot.init) } }
  func value() throws -> Rows {
    guard decltypes.count == columns.count, rows.allSatisfy({ $0.count == columns.count }) else { throw WorkerProtocolError(.invalidMessage, message: "Invalid query row shape") }
    return try .init(columns: columns, decltypes: decltypes, rows: rows.map { try $0.map { try $0.value() } })
  }
}

struct RowEditSnapshot: Codable, Sendable {
  struct Field: Codable, Sendable { let name: String; let value: JSONValue }
  let kind: String
  let id: Int64?
  let fields: [Field]
  init(_ edit: RowEdit) {
    switch edit {
    case let .insert(values): kind = "insert"; id = nil; fields = values.map { .init(name: $0.key, value: $0.value) }
    case let .update(id, values): kind = "update"; self.id = id; fields = values.map { .init(name: $0.key, value: $0.value) }
    case let .delete(id): kind = "delete"; self.id = id; fields = []
    }
  }

  func value() throws -> RowEdit {
    guard Set(fields.map(\.name)).count == fields.count else { throw WorkerProtocolError(.invalidMessage, message: "Duplicate row edit field") }
    let values = OrderedDictionary(uniqueKeysWithValues: fields.map { ($0.name, $0.value) })
    switch kind {
    case "insert" where id == nil: return .insert(values)
    case "update": if let id { return .update(id: id, values) }
    case "delete" where fields.isEmpty: if let id { return .delete(id: id) }
    default: break
    }
    throw WorkerProtocolError(.invalidMessage, message: "Invalid row edit snapshot")
  }
}
