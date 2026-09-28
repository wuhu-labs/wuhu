import Foundation
import SessionDomain
import Testing

@Suite struct LegacyDecodingTests {
  private func reshaped<T: Codable>(_ value: T, _ edit: (inout [String: Any]) -> Void) throws -> T {
    var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? [String: Any])
    edit(&object)
    return try JSONDecoder().decode(T.self, from: JSONSerialization.data(withJSONObject: object))
  }

  @Test func `a stored tool state from before repository context decodes with no folders`() throws {
    let stored = ToolExecutionState(fileAccessLog: ["/a.md": .journal(3)], folderRoots: ["machines://m1/repo": nil])
    let decoded = try reshaped(stored) {
      $0["folderRoots"] = nil
      $0["mounts"] = ["stack": [["location": "/notes"]], "emittedVersions": ["/notes": 1]]
    }
    #expect(decoded == ToolExecutionState(fileAccessLog: ["/a.md": .journal(3)]))
  }

  @Test func `a notification from before repository context decodes without folder roots`() throws {
    let stored = SystemNotification(
      id: UUID(), timestamp: Date(timeIntervalSince1970: 0), kind: .timer, subscriptionID: .init("tim-1"),
      folderRoots: ["machines://m1/repo": nil], content: .init(text: "tick"),
    )
    let decoded = try reshaped(stored) { $0["folderRoots"] = nil }
    #expect(decoded.folderRoots == nil)
    #expect(decoded.content == stored.content)
    var tools = ToolExecutionState()
    tools.apply(delivered: .notification(decoded))
    #expect(tools.folderRoots.isEmpty)
  }

  @Test func `a generation head that still lists mounts to redeclare decodes`() throws {
    let decoded = try reshaped(StateSnapshot(preReads: ["/a.md"])) {
      $0["mountsToRedeclare"] = [["location": "machines://m1"]]
    }
    #expect(decoded == StateSnapshot(preReads: ["/a.md"]))
  }

  @Test func `a mount result from an old transcript still decodes and renders`() throws {
    let payload = ToolResultPayload.mount(.init(mount: .init(location: "/notes"), contextVersion: 1, contextEmission: "notes manual"))
    let decoded = try JSONDecoder().decode(ToolResultPayload.self, from: JSONEncoder().encode(payload))
    #expect(decoded == payload)
    #expect(decoded.renderedText.contains("notes manual"))
  }
}
