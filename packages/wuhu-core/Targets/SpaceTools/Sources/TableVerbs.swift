import JSONValue
import SpaceContract
import SpaceCore
import SpaceFS

extension SpaceToolContext {
  func createTable(_ address: String, header: SpaceContract.TableHeader) async throws -> JSONValue {
    let target = try await spaceTarget(address)
    try await refuseWrite(target.path, in: target.group)
    let rev = try await space.createTable(target.path, header: checkedHeader(header), in: target.group, acting: principal.group)
    return tableWrite(rev)
  }

  func tableSchema(_ address: String, rev: Int? = nil) async throws -> JSONValue {
    let target = try await spaceTarget(address)
    if let rev, rev < 0 { throw SpaceError.invalidRevision(rev) }
    let (header, token) = try await space.tableSchema(target.path, in: target.group, rev: rev.map(Rev.init))
    let columns: [JSONValue] = try header.columns.map { column in
      let type: String = switch column.type {
      case .text: "string"
      case .integer: "integer"
      case .real: "number"
      case .boolean: "boolean"
      case .json: "json"
      case .blob: throw ToolRunError.failed(code: .unsupported, message: "blob columns have no table header wire type", hint: nil)
      }
      return ["name": .string(column.name), "type": .string(type)]
    }
    return ["header": ["columns": .array(columns)], "token": .string(Wire.string(token))]
  }

  func alterTable(_ address: String, header: SpaceContract.TableHeader, ifMatch: String, allowDropColumns: Bool = false) async throws -> JSONValue {
    let target = try await spaceTarget(address)
    try await refuseWrite(target.path, in: target.group)
    let header = try checkedHeader(header)
    do {
      return try await tableWrite(space.alterTable(target.path, header: header, in: target.group, acting: principal.group, ifMatch: Wire.token(ifMatch), allowDropColumns: allowDropColumns))
    } catch SpaceError.versionMismatch {
      let current = try? await space.tableSchema(target.path, in: target.group).token
      throw ToolRunError.failed(code: .conflict, message: "version mismatch: \(address)", hint: Wire.staleHint, token: current.map(Wire.string))
    }
  }

  func commitRows(_ address: String, ops: [SpaceCore.RowOp]) async throws -> RowCommit {
    let target = try await spaceTarget(address)
    try await refuseWrite(target.path, in: target.group)
    return try await space.commitRows(target.path, ops, in: target.group, acting: principal.group, attribution: attribution)
  }

  func instantiateTemplate(_ address: String, in destination: String? = nil) async throws -> JSONValue {
    let template = try await spaceTarget(address)
    var target: (group: GroupID, path: SpacePath, qualified: Bool)?
    if let destination { target = try await spaceTarget(destination) }
    try await refuseWrite(target?.path ?? template.path.parent, in: target?.group ?? template.group)
    let created = try await space.instantiate(template: template.path, of: template.group, in: target?.path, of: target?.group ?? template.group, acting: principal.group)
    let group = target?.group ?? template.group
    let qualified = target?.qualified ?? template.qualified
    return ["path": .string(qualified ? FSResolver.address(created.rawValue, inGroup: group.rawValue) : created.rawValue)]
  }
}

private func tableWrite(_ rev: Rev) -> JSONValue {
  ["rev": .integer(rev.value), "token": .string(String(rev.value))]
}

private func checkedHeader(_ header: SpaceContract.TableHeader) throws -> SpaceCore.TableHeader {
  guard header.columns.count <= 256 else { throw SpaceError.invalidTableHeader("a table header is limited to 256 columns") }
  var names = Set<String>()
  let columns: [TableColumn] = try header.columns.map { column in
    guard !column.name.isEmpty, column.name.utf8.count <= 256,
          !column.name.unicodeScalars.contains(where: { $0.value < 32 || (127 ... 159).contains($0.value) }),
          column.name.lowercased() != "id", names.insert(column.name.lowercased()).inserted
    else { throw SpaceError.invalidTableHeader("column names must be nonempty, unique (case-insensitive), at most 256 UTF-8 bytes, contain no controls, and not be id") }
    let type: TableColumn.ColumnType = switch column.type {
    case .string: .text
    case .integer: .integer
    case .number: .real
    case .boolean: .boolean
    case .json: .json
    }
    return TableColumn(name: column.name, type: type)
  }
  return SpaceCore.TableHeader(columns: columns)
}
