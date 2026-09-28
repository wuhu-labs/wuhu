import Foundation
import GRDB
import JSONValue
import struct SpaceContract.GroupID
import SpaceFS
import StructuredQueries
import StructuredQueriesSQLite

extension Space {
  /// With no `destination`, the instance lands next to its template, in the template's group.
  public func instantiate(
    template templatePath: SpacePath, of templateGroup: GroupID,
    in destination: SpacePath?, of destinationGroup: GroupID,
    acting: GroupID,
  ) async throws -> SpacePath {
    let group = destination == nil ? templateGroup : destinationGroup
    let templatePath = try await MachineFolders.stored(templatePath, mutating: false, in: writer)
    let mtime = SQLiteDateFormat.string(from: dateGen.now)
    let now = dateGen.now
    let text = try await blobs.read(writer) { db, cache in
      guard let head = try Substrate.head(templatePath, group: templateGroup, in: db), head.kind == "file", let hash = head.blobHash else {
        throw SpaceError.notFound(templatePath.rawValue)
      }
      guard let text = String(bytes: try cache.blob(of: hash, in: db).content, encoding: .utf8) else {
        throw SpaceError.templateInvalid(templatePath.rawValue)
      }
      return text
    }
    let spec = try Templates.parse(text, path: templatePath)
    let blob = try await blobs.stage(Array(spec.instanceContent.utf8))
    let (created, rev): (SpacePath, Int64) = try await writer.write { db in
      let directory = try MachineFolders.stored(destination ?? templatePath.parent, mutating: true, in: db)
      let name = try Templates.allocateName(spec, in: directory, group: group, now: now, in: db)
      let target = try SpacePath(validating: directory.isRoot ? "/\(name)" : "\(directory.rawValue)/\(name)")
      if try target.isReserved || Substrate.head(target, group: group, in: db) != nil
        || Substrate.tableExists(target, group: group, in: db)
      {
        throw SpaceError.alreadyExists(target.rawValue)
      }
      let rev = try Substrate.mintRevision(mtime: mtime, group: acting, in: db)
      try Substrate.writeFile(target, group: group, blob: blob, rev: rev, mtime: mtime, in: db)
      return (target, rev)
    }
    broadcast.emit(MutationEvent(group: group, path: created.rawValue, rev: Int(rev), kind: .write, entry: .file))
    return created
  }

  public func importFolder(_ url: URL) async throws {
    let live = fs(.shared)
    for (relative, fileURL) in try Self.regularFiles(under: url).sorted(by: { $0.0 < $1.0 }) {
      let path = try SpacePath(validating: "/" + relative)
      if relative.hasSuffix(".table") {
        let text = try String(contentsOf: fileURL, encoding: .utf8)
        let (header, rows) = try Self.parseTableCSV(text)
        _ = try await createTable(path, header: header, in: .shared, acting: .shared)
        if !rows.isEmpty { _ = try await mutateRows(path, rows.map { RowOp.insert($0) }, in: .shared, acting: .shared) }
      } else {
        _ = try await live.write(path.rawValue, try Data(contentsOf: fileURL), ifMatch: nil)
      }
    }
  }

  public func exportFolder(_ url: URL) async throws {
    let manager = FileManager.default
    try manager.createDirectory(at: url, withIntermediateDirectories: true)

    let files = try await writer.read { db in try FSHeadRow.where { $0.grp.eq(GroupID.shared.rawValue) && $0.kind.eq("file") }.fetchAll(db) }
    for head in files {
      guard let hash = head.blobHash else { continue }
      let content = try await blobs.read(writer) { db, cache in try cache.blob(of: hash, in: db).content }
      try Self.writeFile(Data(content), to: url, relative: head.path, manager: manager)
    }

    let tables = try await writer.read { db in
      try String.fetchAll(db, sql: "SELECT path FROM tables WHERE grp = ? ORDER BY path", arguments: [GroupID.shared.rawValue])
    }
    for table in tables {
      let csv = try await Self.renderTableCSV(try SpacePath(validating: table), writer: writer)
      try Self.writeFile(Data(csv.utf8), to: url, relative: table, manager: manager)
    }
  }

  private static func writeFile(_ data: Data, to root: URL, relative path: String, manager: FileManager) throws {
    let destination = root.appending(path: String(path.dropFirst()))
    try manager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
    try data.write(to: destination)
  }

  private static func regularFiles(under root: URL) throws -> [(String, URL)] {
    let manager = FileManager.default
    let base = root.standardizedFileURL.path
    guard let enumerator = manager.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey]) else {
      return []
    }
    var result: [(String, URL)] = []
    for case let fileURL as URL in enumerator {
      guard try fileURL.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { continue }
      var relative = fileURL.standardizedFileURL.path
      if relative.hasPrefix(base + "/") { relative.removeFirst(base.count + 1) }
      result.append((relative, fileURL))
    }
    return result
  }

  private static func parseTableCSV(_ text: String) throws -> (TableHeader, [[JSONValue]]) {
    let rows = CSV.parse(text)
    guard let headerRow = rows.first else { return (TableHeader(columns: []), []) }
    let columns = try headerRow.map { cell -> TableColumn in
      guard let separator = cell.lastIndex(of: ":"),
            let type = columnType(csvName: String(cell[cell.index(after: separator)...]))
      else { throw SpaceError.importInvalid("table CSV header cell must be name:type, got \(cell)") }
      return TableColumn(name: String(cell[..<separator]), type: type)
    }
    let header = TableHeader(columns: columns)
    let dataRows = try rows.dropFirst().map { record -> [JSONValue] in
      try (0 ..< header.columns.count).map { index in
        guard index < record.count else { return JSONValue.null }
        guard let value = JSONValue.parse(record[index]) else {
          throw SpaceError.importInvalid("table CSV cell must be a JSON literal, got \(record[index])")
        }
        return value
      }
    }
    return (header, dataRows)
  }

  // Dev-loop CSV headers speak the contract ColumnType vocabulary
  // (string/integer/number/boolean/json), not SQLite storage names.
  private static func csvTypeName(_ type: TableColumn.ColumnType) -> String {
    switch type {
    case .text: "string"
    case .real: "number"
    case .integer, .blob, .boolean, .json: type.rawValue
    }
  }

  private static func columnType(csvName: String) -> TableColumn.ColumnType? {
    switch csvName {
    case "string": .text
    case "number": .real
    case "integer": .integer
    case "boolean": .boolean
    case "json": .json
    case "blob": .blob
    default: nil
    }
  }

  private static func renderTableCSV(_ path: SpacePath, writer: any DatabaseWriter) async throws -> String {
    try await writer.read { db in
      let header = try Tables.currentHeader(path, group: .shared, in: db)
      var lines = [CSV.renderRow(header.columns.map { "\($0.name):\(csvTypeName($0.type))" })]
      if !header.columns.isEmpty {
        let columnList = header.columns.map { Cells.quote($0.name) }.joined(separator: ", ")
        let dataRows = try Row.fetchAll(
          db,
          sql: "SELECT \(columnList) FROM \(Tables.quoted(.shared, path)) ORDER BY \"id\"",
        )
        for row in dataRows {
          lines.append(CSV.renderRow(header.columns.indices.map { index in
            let value: DatabaseValue = row[index]
            // A json column already stores the canonical JSON literal.
            if header.columns[index].type == .json, case let .string(stored) = value.storage { return stored }
            return CSV.jsonLiteral(from: value)
          }))
        }
      }
      return lines.joined(separator: "\n") + "\n"
    }
  }
}
