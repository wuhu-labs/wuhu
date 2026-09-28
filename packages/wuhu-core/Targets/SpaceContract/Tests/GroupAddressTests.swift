import SpaceContract
import Testing

// The one parser of `wuhu://<group>.localspace/<path>`: the tools, the HTTP
// routes, the CLI and the client all read a group address through it.
@Suite struct GroupAddressTests {
  func split(_ spelling: String) throws -> [String]? {
    try GroupID.address(spelling).map { [$0.group.rawValue, $0.path] }
  }

  @Test func aGroupHostNamesTheGroupComparedLowercased() throws {
    #expect(try split("wuhu://shared.localspace/a/b.md") == ["shared", "/a/b.md"])
    #expect(try split("WUHU://Shared.LocalSpace/a") == ["shared", "/a"])
    #expect(try split("wuhu://sail-clock-pepper.localspace") == ["sail-clock-pepper", "/"])
    #expect(try GroupID.named(byHost: "Ops.localspace") == GroupID(rawValue: "ops"))
    #expect(GroupID(rawValue: "ops").address("/x.md") == "wuhu://ops.localspace/x.md")
  }

  @Test func anythingElseIsNotAGroupAddress() throws {
    for spelling in ["/a.md", "wuhu://system/AGENTS.md", "wuhu://space.example:5530/a", "machines://box/a", "https://shared.localspace/a"] {
      #expect(try split(spelling) == nil, "\(spelling)")
    }
  }

  @Test func aLocalspaceHostNamingNoGroupIsInvalid() {
    for spelling in ["wuhu://localspace/x", "wuhu://.localspace/x", "wuhu://Bad_Id.localspace/x", "wuhu://-a.localspace/x"] {
      #expect(throws: InvalidGroupHost.self, "\(spelling)") { try GroupID.address(spelling) }
    }
  }
}
