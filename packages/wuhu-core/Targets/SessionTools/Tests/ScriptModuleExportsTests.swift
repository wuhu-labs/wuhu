import JSONValue
@testable import SessionTools
import SystemFiles
import Testing

@Suite struct ScriptModuleExportsTests {
  @Test func generatedInventoryMatchesActualInstalledNamespaces() async throws {
    try await withRig { rig in
      let actual = try await rig.evaluate(#"""
      import * as space from "wuhu:space"
      import * as session from "wuhu:session"
      import * as machine from "wuhu:machine"
      import * as ai from "wuhu:ai"
      import * as secret from "wuhu:secret"
      import * as search from "wuhu:web_search"
      result(Object.fromEntries(Object.entries({"wuhu:space":space,"wuhu:session":session,"wuhu:machine":machine,"wuhu:ai":ai,"wuhu:secret":secret,"wuhu:web_search":search}).map(([name,exports])=>[name,Object.keys(exports).sort()])))
      """#)
      print("MODULE_EXPORTS=" + actual.jsonString(sortedKeys: true))
      let bytes = try await SystemFiles.vfs.read("/module-exports.json").1
      let expected = try #require(JSONValue.parse(String(decoding: bytes, as: UTF8.self)))
      #expect(actual == expected, "Generated module inventory: \(actual.jsonString(sortedKeys: true))")
    }
  }
}
