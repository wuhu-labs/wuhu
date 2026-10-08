import Fetch
import Foundation
import JSONValue
import Scratch
import SpaceContract
@testable import SpaceServer
import Testing
import WuhuVFS

@Suite struct AIDisclosureTests {
  let disclosure = AIDisclosure(version: "trial-2026-10", providers: [
    AIProviderDisclosure(name: "DeepSeek", location: "China", via: "Wuhu metering proxy", policy: "https://wuhu.ai/privacy"),
  ])

  @Test func configuredDiscoveryAndCodableCompatibility() async throws {
    let h = try Harness(dev: false, aiDisclosure: disclosure)
    let response = try await h.api(Request(url: URL(string: "https://localhost/v1/server")!))
    #expect(response.status == .ok)
    let data = Data(try await response.text().utf8)
    let info = try JSONDecoder().decode(ServerInfo.self, from: data)
    #expect(info.aiDisclosure == disclosure)
    let old = Data(#"{"features":["groups"],"group":"shared"}"#.utf8)
    #expect(try JSONDecoder().decode(ServerInfo.self, from: old).aiDisclosure == nil)
    let encoded = try JSONEncoder().encode(ServerInfo(group: "shared"))
    #expect(JSONValue.parse(String(decoding: encoded, as: UTF8.self))?.object?["aiDisclosure"] == nil)
  }

  @Test func unconfiguredDiscoveryIsByteIdentical() async throws {
    let h = try Harness(dev: false, origin: "https://space.test")
    let identity = try await h.space.identity().rawValue
    let response = try await h.api(Request(url: URL(string: "https://space.test/v1/server")!))
    #expect(try await response.text() == "{\"space\":\"\(identity)\",\"origin\":\"https://space.test\",\"contentBase\":\"space.test\",\"features\":[\"groups\"],\"group\":\"shared\"}")
  }

  @Test func readsConfiguredFileThroughVFS() async throws {
    let fs = NodeTreeVFS(root: InMemoryVFSNode())
    try await fs.createFile(at: VFSPath(absoluteFilePath: "/disclosure.json"), data: JSONEncoder().encode(disclosure))
    #expect(try await loadAIDisclosure(from: fs, path: "/disclosure.json", file: "disclosure.json") == disclosure)
    await #expect(throws: AIDisclosureError.unreadable(file: "missing.json")) {
      try await loadAIDisclosure(from: fs, path: "/missing.json", file: "missing.json")
    }
  }

  @Test(arguments: [
    "not json", "null", "{}", #"{"version":"v","providers":[]}"#,
    #"{"version":" ","providers":[{"name":"DeepSeek","location":"China","via":"proxy","policy":"https://wuhu.ai/privacy"}]}"#,
    #"{"version":"v","providers":[{"name":"DeepSeek","location":"China","policy":"https://wuhu.ai/privacy"}]}"#,
    #"{"version":"v","providers":[{"name":"","location":"China","via":"proxy","policy":"https://wuhu.ai/privacy"}]}"#,
    #"{"version":"v","providers":[{"name":"DeepSeek","location":"China","via":"proxy","policy":"/privacy"}]}"#,
    #"{"version":"v","providers":[{"name":"DeepSeek","location":"China","via":"proxy","policy":"http://wuhu.ai/privacy"}]}"#,
  ]) func malformedFileIsTypedFailure(_ json: String) async throws {
    let fs = NodeTreeVFS(root: InMemoryVFSNode())
    try await fs.createFile(at: VFSPath(absoluteFilePath: "/bad.json"), data: Data(json.utf8))
    await #expect(throws: AIDisclosureError.invalid(file: "bad.json")) {
      try await loadAIDisclosure(from: fs, path: "/bad.json", file: "bad.json")
    }
  }

  @Test func badConfigRefusesBeforeCreatingStore() async throws {
    let dir = try scratchURL("ai-disclosure")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let file = dir.appendingPathComponent("bad.json")
    let store = dir.appendingPathComponent("store")
    await #expect(throws: AIDisclosureError.unreadable(file: file.path)) {
      try await SpaceServer.serve(folder: store, port: 0, dev: true, aiDisclosureFile: file)
    }
    try Data("{}".utf8).write(to: file)
    await #expect(throws: AIDisclosureError.invalid(file: file.path)) {
      try await SpaceServer.serve(folder: store, port: 0, dev: true, aiDisclosureFile: file)
    }
    #expect(!FileManager.default.fileExists(atPath: store.path))
  }
}
