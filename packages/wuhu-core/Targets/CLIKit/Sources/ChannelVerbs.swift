import JSONValue
import struct SpaceContract.ConversationPostOutput

extension Executor {
  mutating func channel(_ operation: ChannelCommand) async throws {
    let space = try self.wallet.pinnedSpace()
    let client = try await self.authenticated(space)
    switch operation {
    case let .create(title, people):
      let output: ConversationPostOutput = try await client.api(.post, "/v1/conversation", body: JSONValue.object([
        "title": title.map(JSONValue.string) ?? .null,
        "members": .array(people.map(JSONValue.string)),
      ]))
      await self.runner.stdout(output.conversationId + "\n")
    case let .members(id, people, add):
      let _: JSONValue = try await client.api(.post, "/v1/channel/\(id)/\(add ? "add" : "remove")", body: JSONValue.object([
        "people": .array(people.map(JSONValue.string)),
      ]))
    case let .rename(id, title):
      let _: JSONValue = try await client.api(.post, "/v1/channel/\(id)/rename", body: JSONValue.object([
        "title": title.map(JSONValue.string) ?? .null,
      ]))
    }
  }
}
