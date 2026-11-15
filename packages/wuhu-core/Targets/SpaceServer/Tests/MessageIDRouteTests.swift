import DeterministicDependencies
#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import Fetch
import JSONValue
import SessionDomain
import struct SpaceContract.ConversationPostOutput
@testable import SpaceCore
@testable import SpaceServer
import Testing

@Suite(.deterministicDependencies) struct MessageIDRouteTests {
  private let minted = "6F9619FF-8B86-D011-B42D-00C04FC964FF"

  private func code(_ response: Response) async throws -> JSONValue? {
    JSONValue.parse(try await response.text())?.object?["code"]
  }

  @Test func aPersonsMessageIdNamesTheMessageAndAResendAnswersTheSameReceipt() async throws {
    try await withSessionDeps {
      let t = try await SessionGateTests().tree()
      let person = try await t.harness.space.ensureDevPerson().persona
      let post: JSONValue = [
        "session": .string(t.parent.rawValue), "identity": .string(person), "message": "once", "messageId": .string(minted),
      ]
      let sent = try await t.harness.call("/v1/conversation/message", post, as: ConversationPostOutput.self)
      let resent = try await t.harness.call("/v1/conversation/message", post, as: ConversationPostOutput.self)
      #expect(sent.messageId == minted.lowercased())
      #expect(sent.delivered == [t.parent.rawValue])
      #expect(resent.messageId == sent.messageId)
      #expect(resent.n == sent.n)
      #expect(resent.delivered.isEmpty)
      #expect(try await t.harness.store.messages(conversation: .init(t.parent.rawValue)).map(\.content.text) == ["once"])
    }
  }

  @Test func aMessageIdThatIsNotAUUIDIsRefused() async throws {
    try await withSessionDeps {
      let t = try await SessionGateTests().tree()
      let person = try await t.harness.space.ensureDevPerson().persona
      let response = try await t.harness.post("/v1/conversation/message", [
        "session": .string(t.parent.rawValue), "identity": .string(person), "message": "hi", "messageId": "m1",
      ])
      #expect(response.status == .badRequest)
      #expect(try await code(response) == "invalidArgument")
      #expect(try await t.harness.store.messages(conversation: .init(t.parent.rawValue)).isEmpty)
    }
  }

  @Test func anotherPersonsMessageIdIsAConflict() async throws {
    try await withSessionDeps {
      let t = try await SessionGateTests().tree()
      let person = try await t.harness.space.ensureDevPerson().persona
      let (bearer, key) = try await t.harness.enrolledBearer()
      let other = try await t.harness.space.adoptPersona(key: key).name
      _ = try await t.harness.call("/v1/conversation/message", [
        "session": .string(t.parent.rawValue), "identity": .string(person), "message": "mine", "messageId": .string(minted),
      ], as: ConversationPostOutput.self)
      let response = try await t.harness.post("/v1/conversation/message", [
        "session": .string(t.parent.rawValue), "identity": .string(other), "message": "also mine", "messageId": .string(minted),
      ], bearer: bearer)
      #expect(response.status == .conflict)
      #expect(try await code(response) == "conflict")
      #expect(try await t.harness.store.messages(conversation: .init(t.parent.rawValue)).map(\.content.text) == ["mine"])
    }
  }

  @Test func aSessionSettingMessageIdIsRefused() async throws {
    try await withSessionDeps {
      let t = try await SessionGateTests().tree()
      let response = try await t.harness.post("/v1/conversation/message", [
        "session": .string(t.stranger.rawValue), "message": "hi", "messageId": .string(minted),
      ], bearer: t.token)
      #expect(response.status == .badRequest)
      #expect(try await code(response) == "invalidArgument")
      #expect(try await t.harness.store.sent(t.stranger).isEmpty)
    }
  }
}
