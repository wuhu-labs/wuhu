#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import struct DocIndex.DocumentTemplate
import JSONValue
import struct SpaceContract.GroupID
import SpaceFS

extension Space {
  /// With no `destination`, the instance lands next to its template, in the template's group.
  public func instantiate(
    template templatePath: SpacePath, of templateGroup: GroupID,
    in destination: SpacePath?, of destinationGroup: GroupID,
    acting: GroupID, attribution: RevisionAttribution? = nil,
  ) async throws -> SpacePath {
    let group = destination == nil ? templateGroup : destinationGroup
    let templatePath = try await MachineFolders.stored(templatePath, mutating: false, in: runtime)
    let mtime = SQLiteDateFormat.string(from: dateGen.now)
    let now = dateGen.now
    let hash = try worker.cell(FilesCell.ID(templateGroup.rawValue)).fileContents(templatePath).hash
    guard let text = String(bytes: try await bucket.bytes(hash), encoding: .utf8) else {
      throw SpaceError.templateInvalid(templatePath.rawValue)
    }
    guard let template = DocumentTemplate(markdown: text, at: templatePath) else { throw SpaceError.templateInvalid(templatePath.rawValue) }
    let content = Array(template.instance.utf8)
    let blob = try await bucket.stage(content)
    let directory = try await MachineFolders.stored(destination ?? templatePath.parent, mutating: true, in: runtime)
    let (created, written) = try await worker.call(FilesCell.ID(group.rawValue)) {
      try $0.instantiate(template, in: directory, blob: blob, now: now, mtime: mtime, attribution: attribution)
    }
    if !written {
      _ = try await documents.write(
        group, created, Data(content), base: .latest, createOnly: true, acting: acting, attribution: attribution,
      )
    }
    return created
  }

  public func importFolder(_ url: URL) async throws {
    let live = fs(.shared)
    let settings = fs(.settings)
    for (relative, fileURL) in try Self.regularFiles(under: url).sorted(by: { $0.0 < $1.0 }) {
      let path = try SpacePath(validating: "/" + relative)
      if relative.hasSuffix(".table") {
        let text = try String(contentsOf: fileURL, encoding: .utf8)
        let (header, rows) = try Self.parseTableCSV(text)
        _ = try await createTable(path, header: header, in: .shared, acting: .shared)
        if !rows.isEmpty { _ = try await mutateRows(path, rows.map { RowOp.insert($0) }, in: .shared, acting: .shared) }
      } else if Self.settingsDocuments.contains(path.rawValue) {
        _ = try await settings.write(path.rawValue, try Data(contentsOf: fileURL), ifMatch: nil)
      } else {
        _ = try await live.write(path.rawValue, try Data(contentsOf: fileURL), ifMatch: nil)
      }
    }
  }

  /// The space's settings files: an import writes them to the settings group,
  /// and a hosted seed lands them there.
  public static let settingsDocuments: Set<String> = [
    "/models.json", "/model-groups.json", "/capabilities.json", "/machine-v2-upgrade.json",
  ]

  public func exportFolder(_ url: URL) async throws {
    let manager = FileManager.default
    try manager.createDirectory(at: url, withIntermediateDirectories: true)

    let files = worker.cell(FilesCell.ID(GroupID.shared.rawValue)).fileHeads()
    for head in files {
      let hash = head.blobHash!
      let content = try await bucket.bytes(hash)
      try Self.writeFile(Data(content), to: url, relative: head.path, manager: manager)
    }

    let tables = worker.cell(FilesCell.ID(GroupID.shared.rawValue)).tablePaths()
    for table in tables {
      let csv = try renderTableCSV(try SpacePath(validating: table))
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

  private func renderTableCSV(_ path: SpacePath) throws -> String {
    let (header, rows) = try worker.cell(FilesCell.ID(GroupID.shared.rawValue)).exportTable(path)
    var lines = [CSV.renderRow(header.columns.map { "\($0.name):\(Self.csvTypeName($0.type))" })]
    for row in rows {
      lines.append(CSV.renderRow(header.columns.indices.map { index in
        if header.columns[index].type == .json, case let .text(stored) = row[index] { return stored }
        return CSV.jsonLiteral(from: row[index])
      }))
    }
    return lines.joined(separator: "\n") + "\n"
  }
}
