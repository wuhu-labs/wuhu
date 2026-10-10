import Foundation
import JSONValue
import SessionDomain
import SpaceCore
import Testing

@Suite struct ScriptChannelTests {
  @Test func sessionCreatesAndManagesAChannelWithTwoPeopleFromAScript() async throws {
    try await withRig { rig in
      var people: [String] = []
      for seed in UInt8(1) ... UInt8(3) {
        let account = try await rig.space.addAccount(kind: .human, name: nil)
        let key = try await rig.space.addKey("ed25519:" + Data(repeating: seed, count: 32).base64EncodedString(), account: account.id, capabilities: [.device], createdBy: nil, expiresAt: nil)
        people.append(try await rig.space.mintPersona(key: key).name)
      }
      let result = try await rig.evaluate("""
      import { createChannel, addChannelMembers, removeChannelMembers, renameChannel, conversation } from "wuhu:space"
      const id = await createChannel({ title: "People", people: \(JSONValue.array(people.prefix(2).map(JSONValue.string)).jsonString()) })
      await addChannelMembers(id, ["\(people[2])"])
      await removeChannelMembers(id, ["\(people[2])"])
      await renameChannel(id, "Team")
      const page = await conversation(id)
      let code
      try { await addChannelMembers(id, [import.meta.session]) } catch (e) { code = e.code }
      result({ id, page, code })
      """)
      let id = try #require(result.object?["id"]?.stringValue)
      let record = try await rig.space.sessions.conversation(ConversationID(id))
      #expect(record.title == "Team")
      #expect(Set(record.members.map(\.member)) == Set(people.prefix(2)))
      #expect(record.members.allSatisfy { $0.kind == .user })
      #expect(result.object?["code"] == "invalidArgument")
      #expect(result.object?["page"]?.object?["messages"] == .array([]))
    }
  }
}
