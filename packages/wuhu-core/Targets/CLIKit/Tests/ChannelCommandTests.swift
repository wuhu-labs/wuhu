@testable import CLIKit
import JSONValue
import Testing

@Suite struct ChannelCommandTests {
  @Test func channelCommandsHaveScriptParityAndRejectIncompleteArguments() throws {
    #expect(try Command.parse(["channel", "create", "--title", "Team", "alice", "bob"]) == .channel(.create(title: "Team", people: ["alice", "bob"])))
    #expect(try Command.parse(["channel", "add", "team", "carol"]) == .channel(.members(id: "team", people: ["carol"], add: true)))
    #expect(try Command.parse(["channel", "remove", "team", "carol"]) == .channel(.members(id: "team", people: ["carol"], add: false)))
    #expect(try Command.parse(["channel", "rename", "team", "New"]) == .channel(.rename(id: "team", title: "New")))
    #expect(try Command.parse(["channel", "rename", "team", "--clear"]) == .channel(.rename(id: "team", title: nil)))
    #expect(throws: (any Error).self) { try Command.parse(["channel", "add", "team"]) }
    #expect(throws: (any Error).self) { try Command.parse(["channel", "create", "--bogus"]) }
    #expect(throws: (any Error).self) { try Command.parse(["channel", "rename", "team"]) }
  }
}
