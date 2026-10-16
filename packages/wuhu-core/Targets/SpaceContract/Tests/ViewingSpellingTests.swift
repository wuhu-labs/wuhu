import Foundation
import SpaceContract
import Testing

struct ViewingVectors: Decodable {
  struct Spelled: Decodable {
    let group: String
    let path: String
    let viewing: String
  }

  struct Cases: Decodable {
    let cases: [Spelled]
  }

  struct Paths: Decodable {
    let paths: [String]
  }

  let named: Cases
  let unnamed: Cases
  let omitted: Paths

  static let shared: ViewingVectors = {
    let file = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .appendingPathComponent("contract/viewing-vectors.json")
    return try! JSONDecoder().decode(ViewingVectors.self, from: Data(contentsOf: file))
  }()
}

@Suite struct ViewingSpellingTests {
  @Test func aShownPathIsNamedGroupQualified() {
    for vector in ViewingVectors.shared.named.cases {
      #expect(GroupID(rawValue: vector.group).viewing(vector.path) == vector.viewing, "\(vector.path)")
    }
  }

  @Test func theRootNamesNoPage() {
    for vector in ViewingVectors.shared.unnamed.cases {
      #expect(GroupID(rawValue: vector.group).viewing(vector.path) == nil, "\(vector.path)")
    }
  }

  @Test func whatTheServerWouldRefuseIsOmitted() {
    for path in ViewingVectors.shared.omitted.paths {
      #expect(GroupID.shared.viewing(path) == nil, "\(path)")
    }
  }

  /// A send only builds a spelling from a space path, never from a relative or system one; the
  /// server never sees these.
  @Test(arguments: ["notes/plan.md", "wuhu://system/AGENTS.md"])
  func aPathThatIsNotASpacePathIsOmitted(path: String) {
    #expect(GroupID.shared.viewing(path) == nil)
  }

  @Test(arguments: ["", "Shared", "-shared", "sh.ared"])
  func aPathInAnInvalidGroupIsOmitted(group: String) {
    #expect(GroupID(rawValue: group).viewing("/plan.md") == nil)
  }

  @Test func theSpellingIsAtMost1024Bytes() {
    let prefix = "wuhu://shared.localspace/".utf8.count
    let fits = "/" + String(repeating: "a", count: GroupID.viewingMaxBytes - prefix)
    #expect(GroupID.shared.viewing(fits)?.utf8.count == GroupID.viewingMaxBytes)
    #expect(GroupID.shared.viewing(fits + "a") == nil)
    let wide = "/" + String(repeating: "日", count: (GroupID.viewingMaxBytes - prefix) / 3 + 1)
    #expect(GroupID.shared.viewing(wide) == nil)
  }
}
