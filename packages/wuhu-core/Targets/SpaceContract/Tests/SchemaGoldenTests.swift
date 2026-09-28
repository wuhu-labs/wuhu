import Contract
import Foundation
import SpaceContract
import Testing

@Suite
struct SchemaGoldenTests {
  private static let contractDir = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent() // Tests
    .appendingPathComponent("contract")

  @Test func everySchemaMatchesCheckedInFile() throws {
    for (name, schema) in ContractSchemas.all {
      let file = Self.contractDir.appendingPathComponent(SchemaDocument.fileName(forType: name))
      let onDisk = try String(contentsOf: file, encoding: .utf8)
      #expect(onDisk == SchemaDocument.document(named: name, schema: schema), "stale contract fixture for \(name); run contract-export")
    }
  }

  @Test func checkedInFilesMatchTheRegistryExactly() throws {
    let onDisk = try FileManager.default
      .contentsOfDirectory(at: Self.contractDir, includingPropertiesForKeys: nil)
      .map(\.lastPathComponent)
      .filter { $0.hasSuffix(".schema.json") }
      .sorted()
    let expected = ContractSchemas.all.map { SchemaDocument.fileName(forType: $0.name) }.sorted()
    #expect(onDisk == expected)
  }
}
