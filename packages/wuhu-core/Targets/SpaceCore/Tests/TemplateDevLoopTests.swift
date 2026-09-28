import Foundation
import JSONValue
import Scratch
@testable import SpaceCore
import SpaceFS
import Testing

@Suite struct TemplateTests {
  static let incrTemplate = """
  ---
  template:
    strategy: incr
    prefix: ISSUE
    pad: 4
  kind: issue
  ---
  # New issue
  """

  static let dateTemplate = """
  ---
  template:
    strategy: date
    folders: true
    specificity: minute
  ---
  # Journal
  """

  @Test func incrAllocatesSequentialNames() async throws {
    let space = try makeSpace()
    _ = try await space.writeText("/templates/issue.md", Self.incrTemplate)
    let first = try await space.instantiate(template: path("/templates/issue.md"), of: .shared, in: path("/issues"), of: .shared, acting: .shared)
    let second = try await space.instantiate(template: path("/templates/issue.md"), of: .shared, in: path("/issues"), of: .shared, acting: .shared)

    #expect(first.rawValue == "/issues/ISSUE-0001.md")
    #expect(second.rawValue == "/issues/ISSUE-0002.md")
    #expect(try await space.readText("/issues/ISSUE-0001.md").contains("kind: issue"))
  }

  @Test func concurrentIncrInstantiationNeverCollides() async throws {
    let space = try makeSpace()
    _ = try await space.writeText("/templates/issue.md", Self.incrTemplate)
    let template = try path("/templates/issue.md")
    let destination = try path("/issues")

    let created = try await withThrowingTaskGroup(of: SpacePath.self) { group in
      for _ in 0 ..< 8 {
        group.addTask { try await space.instantiate(template: template, of: .shared, in: destination, of: .shared, acting: .shared) }
      }
      var results: [SpacePath] = []
      for try await path in group { results.append(path) }
      return results
    }

    let names = Set(created.map(\.rawValue))
    #expect(names.count == 8)
    #expect(names == Set((1 ... 8).map { "/issues/ISSUE-\(String(format: "%04d", $0)).md" }))
  }

  @Test func dateTemplateUsesLocalDateFormatAndErrorsOnCollision() async throws {
    let space = try makeSpace()
    _ = try await space.writeText("/templates/journal.md", Self.dateTemplate)
    let created = try await space.instantiate(template: path("/templates/journal.md"), of: .shared, in: path("/journal"), of: .shared, acting: .shared)

    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = .current
    let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: fixedDate)
    let expected = String(
      format: "/journal/%04d/%02d/%02d-%02d-%02d.md",
      parts.year!, parts.month!, parts.day!, parts.hour!, parts.minute!,
    )
    #expect(created.rawValue == expected)

    await #expect(throws: SpaceError.self) {
      _ = try await space.instantiate(template: path("/templates/journal.md"), of: .shared, in: path("/journal"), of: .shared, acting: .shared)
    }
  }
}

@Suite struct DevLoopTests {
  @Test func exportThenImportIsIdentityOnTypedContent() async throws {
    let source = try makeSpace()
    _ = try await source.writeText("/notes/todo.md", "---\nkind: note\nstatus: open\n---\n[ref](/other.md)")
    _ = try await source.writeText("/data/plain.txt", "just bytes\n")
    let table = try path("/data/log.table")
    _ = try await source.createTable(table, header: TableHeader(columns: [
      TableColumn(name: "n", type: .integer),
      TableColumn(name: "r", type: .real),
      TableColumn(name: "s", type: .text),
      TableColumn(name: "b", type: .blob),
    ]), in: .shared, acting: .shared)
    let blob = Data([0x00, 0xFF, 0x10]).base64EncodedString()
    _ = try await source.mutateRows(table, [
      .insert([.integer(1), .number(2.5), .string("a,comma"), .string(blob)]),
      .insert([.null, .null, .null, .null]),
      .insert([.integer(3), .number(4.0), .string(""), .string("MQ==")]),
    ], in: .shared, acting: .shared)

    let dirA = try scratch()
    let dirB = try scratch()
    defer {
      try? FileManager.default.removeItem(at: dirA)
      try? FileManager.default.removeItem(at: dirB)
    }

    try await source.exportFolder(dirA)
    let exportedCSV = try String(contentsOf: dirA.appending(path: "data/log.table"), encoding: .utf8)
    #expect(exportedCSV.hasPrefix("n:integer,r:number,s:string,b:blob\n"))

    let roundTrip = try makeSpace()
    try await roundTrip.importFolder(dirA)
    try await roundTrip.exportFolder(dirB)

    #expect(try folderSnapshot(dirA) == folderSnapshot(dirB))

    let typedSQL = "SELECT n, r, s, b FROM \"/data/log.table\" ORDER BY \"id\""
    let sourceRows = try await source.query(typedSQL)
    #expect(try await roundTrip.query(typedSQL) == sourceRows)
    #expect(sourceRows.rows == [
      [.integer(1), .real(2.5), .text("a,comma"), .blob([0x00, 0xFF, 0x10])],
      [.null, .null, .null, .null],
      [.integer(3), .real(4.0), .text(""), .blob(Array("1".utf8))],
    ])

    let docsSQL = "SELECT path, title, kind, status FROM docs ORDER BY path"
    let attrsSQL = "SELECT path, name, ord, value FROM doc_custom_attrs ORDER BY path, name, ord"
    #expect(try await roundTrip.dump(docsSQL) == source.dump(docsSQL))
    #expect(try await roundTrip.dump(attrsSQL) == source.dump(attrsSQL))
  }

  @Test func importRejectsStorageTypeNamesInHeader() async throws {
    let dir = try scratch()
    defer { try? FileManager.default.removeItem(at: dir) }
    try FileManager.default.createDirectory(at: dir.appending(path: "data"), withIntermediateDirectories: true)
    try Data("date:text,weight:real\n".utf8).write(to: dir.appending(path: "data/old.table"))

    let space = try makeSpace()
    await #expect(throws: SpaceError.importInvalid("table CSV header cell must be name:type, got date:text")) {
      try await space.importFolder(dir)
    }
  }

  private func scratch() throws -> URL {
    let url = try scratchURL("space")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  private func folderSnapshot(_ root: URL) throws -> [String: Data] {
    let manager = FileManager.default
    let base = root.standardizedFileURL.path
    guard let enumerator = manager.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey]) else { return [:] }
    var snapshot: [String: Data] = [:]
    for case let fileURL as URL in enumerator {
      guard try fileURL.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { continue }
      var relative = fileURL.standardizedFileURL.path
      if relative.hasPrefix(base + "/") { relative.removeFirst(base.count + 1) }
      snapshot[relative] = try Data(contentsOf: fileURL)
    }
    return snapshot
  }
}
