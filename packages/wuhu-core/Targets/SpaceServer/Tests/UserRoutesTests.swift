import Fetch
import Foundation
import JSONValue
import Serve
import SpaceContract
import Testing

@Suite struct UserRoutesTests {
  @Test func settingAHandleRefusesJunkAndCollisions() async throws {
    try await withSessionDeps {
      let harness = try await SessionHarness()

      let set = try await harness.put("/v1/user/me/profile", .object(["handle": "Owner", "displayName": "The Owner"]))
      #expect(set.status == .ok)
      let payload = try JSONValueDecoder().decode(UserPayload.self, from: try await json(set))
      #expect(payload.handle == "owner")
      #expect(payload.displayName == "The Owner")

      let junk = try await harness.put("/v1/user/me/profile", .object(["handle": "-nope"]))
      #expect(junk.status == .badRequest)

      let stranger = try await harness.mintPersona()
      _ = try await harness.space.setUserProfile(principal: stranger, handle: "taken", displayName: nil)
      let clash = try await harness.put("/v1/user/me/profile", .object(["handle": "TAKEN"]))
      #expect(clash.status == .conflict)
    }
  }

  @Test func theDirectoryListsEveryPersonaAndEveryProfiledPrincipal() async throws {
    try await withSessionDeps {
      let harness = try await SessionHarness()
      let alice = try await harness.mintPersona()
      _ = try await harness.space.setUserProfile(principal: alice, handle: "alice", displayName: nil)
      _ = try await harness.mintPersona()
      _ = try await harness.put("/v1/user/me/profile", .object(["handle": "owner"]))

      let users = try JSONValueDecoder().decode(
        UsersOutput.self, from: try await json(try await harness.get("/v1/users")),
      ).users
      #expect(users.count == 3)
      #expect(users.first { $0.id == alice }?.handle == "alice")
      #expect(users.first { $0.id == "owner" }?.handle == "owner")
      #expect(users.filter { $0.handle == nil }.count == 1)
    }
  }

  @Test func aMessageCarriesTheSenderHandleAndTracksARename() async throws {
    try await withSessionDeps {
      let harness = try await SessionHarness()
      let id = try await harness.createSession()
      let alice = try await harness.mintPersona()
      _ = try await harness.space.setUserProfile(principal: alice, handle: "alice", displayName: nil)

      _ = try await harness.call(
        "/v1/conversation/message",
        .object(["message": "hi", "session": .string(id.rawValue), "identity": .string(alice)]),
        as: ConversationPostOutput.self,
      )

      func readHandle() async throws -> String? {
        try JSONValueDecoder().decode(
          ConversationReadOutput.self,
          from: try await json(try await harness.get("/v1/conversation/\(id.rawValue)/messages")),
        ).messages.first?.senderHandle
      }
      #expect(try await readHandle() == "alice")

      // The handle is resolved at read time, so a rename rewrites history.
      _ = try await harness.space.setUserProfile(principal: alice, handle: "alicia", displayName: nil)
      #expect(try await readHandle() == "alicia")

      let members = try JSONValueDecoder().decode(
        ConversationPayload.self,
        from: try await json(try await harness.get("/v1/session/\(id.rawValue)/conversation")),
      ).members
      #expect(members.first { $0.member == alice }?.memberHandle == "alicia")
    }
  }

  @Test func theObserveStreamCarriesTheSenderHandleToo() async throws {
    try await withSessionDeps {
      let harness = try await SessionHarness()
      let id = try await harness.createSession()
      let alice = try await harness.mintPersona()
      _ = try await harness.space.setUserProfile(principal: alice, handle: "alice", displayName: nil)
      _ = try await harness.call(
        "/v1/conversation/message",
        .object(["message": "streamed", "session": .string(id.rawValue), "identity": .string(alice)]),
        as: ConversationPostOutput.self,
      )

      let response = try await harness.get("/v1/conversation/\(id.rawValue)/observe")
      #expect(response.status == .ok)
      for try await frame in response.sse() {
        let payload = try JSONValueDecoder().decode(
          ConversationMessagePayload.self, from: #require(JSONValue.parse(frame.data)),
        )
        #expect(payload.senderHandle == "alice")
        break
      }
    }
  }
}
