import Contract
import Foundation
import SpaceContract
import SpaceToolReference
import SpaceTools
import Testing

@Suite struct ToolReferenceTests {
  private static let referenceDir = Bundle.module.resourceURL!.appending(path: "reference")

  // The pages' schema links reach the contract target's folder in the checkout,
  // which the pages' own bundle does not hold.
  private static let sourceReferenceDir = URL(fileURLWithPath: "packages/wuhu-core/Targets/SpaceToolReference/Tests/reference")

  @Test func everyPageMatchesCheckedInFile() throws {
    for (fileName, content) in ToolReference.pages() {
      let onDisk = try String(contentsOf: Self.referenceDir.appendingPathComponent(fileName), encoding: .utf8)
      #expect(onDisk == content, "stale tool page \(fileName); run contract-export")
    }
  }

  @Test func checkedInFilesMatchThePagesExactly() throws {
    let onDisk = try FileManager.default
      .contentsOfDirectory(at: Self.referenceDir, includingPropertiesForKeys: nil)
      .map(\.lastPathComponent)
      .sorted()
    #expect(onDisk == ToolReference.pages().map(\.fileName).sorted())
  }

  // A reader follows a page's schema links on disk, so each must reach a
  // checked-in schema file (the contract dir is this test's data).
  @Test func everyLinkedSchemaFileExists() throws {
    var linked = 0
    for (fileName, content) in ToolReference.pages() {
      for match in content.matches(of: #/\]\(([^)#]+\.schema\.json)\)/#) {
        let target = Self.sourceReferenceDir.appendingPathComponent(String(match.1)).standardizedFileURL
        #expect(FileManager.default.fileExists(atPath: target.path), "\(fileName) links \(match.1), which is not a file")
        linked += 1
      }
    }
    #expect(linked > 0)
  }

  @Test func everyToolHasOneEntryNamingItsInputSchema() throws {
    #expect(ToolReference.entries.map(\.tool).sorted() == SpaceToolbox.all.map(\.name).sorted())
    for tool in SpaceToolbox.all {
      let entry = try #require(ToolReference.entries.first { $0.tool == tool.name })
      let input = try #require(ContractSchemas.all.first { $0.name == entry.input }?.schema)
      #expect(input == tool.inputSchema, "\(tool.name) takes \(entry.input)")
      #expect(ContractSchemas.all.contains { $0.name == entry.output }, "\(tool.name) answers \(entry.output)")
    }
  }
}
