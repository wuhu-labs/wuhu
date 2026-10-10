import Fetch
import FetchSSE
import Foundation
import JSONValue
import SessionDomain
import SpaceContract
import SpaceCore
@testable import SpaceServer
import Testing

@Suite struct ChannelReadRouteTests {
  @Test func attachmentsRequireMembershipAcrossFileToolsListingsAndContentHosts() async throws {
    try await withSessionDeps {
      let harness = try await SessionHarness(dev: false, origin: "https://localhost")
      let (aliceBearer, aliceKey) = try await harness.enrolledBearer()
      let (carolBearer, carolKey) = try await harness.enrolledBearer()
      let alice = try await harness.space.mintPersona(key: aliceKey).name
      _ = try await harness.space.mintPersona(key: carolKey)
      let aliceCookie = try await harness.space.createReadSession(account: aliceKey.account, group: .shared, expiresAt: Date().addingTimeInterval(3600))
      let carolCookie = try await harness.space.createReadSession(account: carolKey.account, group: .shared, expiresAt: Date().addingTimeInterval(3600))
      let foreign = try await harness.space.ensurePersonalGroup(account: harness.space.addAccount(kind: .human, name: nil).id)
      try await harness.space.addEdge(src: .shared, dst: foreign, kind: .read, by: nil)
      for group in [GroupID.shared, foreign] {
        let id = try await harness.store.createConversation(members: [alice], in: group)
        let delivery = try await harness.store.post(.conversation(id), messageID: MessageID("attachment-" + group.rawValue), sender: Sender(id: alice, timeZone: .gmt), content: .init(text: "look"), uploads: [AttachmentUpload(name: "secret.txt", bytes: Array("secret".utf8))])
        let path = try #require(delivery.message.content.attachments.first?.path)
        let address = "wuhu://\(group.rawValue).localspace" + path
        #expect(try await harness.get("/v1/f" + path, query: ["group": group.rawValue], bearer: carolBearer).status == .notFound)
        #expect(try await harness.get("/v1/f" + path, query: ["group": group.rawValue], bearer: aliceBearer).status == .ok)
        for tool in ["read", "stat", "ls"] {
          let target = tool == "ls" ? String(address[..<address.lastIndex(of: "/")!]) : address
          let refused = try await harness.post("/v1/tools/" + tool, ["path": .string(target)], bearer: carolBearer)
          let detail = try await refused.text()
          #expect(refused.status == .unprocessableContent, "\(tool): \(detail)")
          #expect(JSONValue.parse(detail)?.object?["code"] == "notFound")
          #expect(try await harness.post("/v1/tools/" + tool, ["path": .string(target)], bearer: aliceBearer).status == .ok)
        }
        let listing = try await harness.post("/v1/tools/ls", ["path": .string("wuhu://\(group.rawValue).localspace/_/conversations")], bearer: carolBearer)
        #expect(listing.status == .ok)
        #expect(try await !listing.text().contains(id.rawValue))
        for (cookie, expected) in [(aliceCookie, 200), (carolCookie, 404)] {
          var request = Request(url: URL(string: "https://shared.localhost" + path)!)
          request.headers[.cookie] = "wuhu_read=" + cookie.rawValue
          #expect(try await harness.api(request).status.code == expected)
        }
        try await harness.store.removeChannelMembers(id, people: [alice], as: Principal(actor: .person(persona: alice, account: aliceKey.account), group: group))
        #expect(try await harness.get("/v1/f" + path, query: ["group": group.rawValue], bearer: aliceBearer).status == .notFound)
        var request = Request(url: URL(string: "https://shared.localhost" + path)!)
        request.headers[.cookie] = "wuhu_read=" + aliceCookie.rawValue
        #expect(try await harness.api(request).status == .notFound)
      }
    }
  }

  @Test func removedMembersCannotCopyChannelAttachmentsIntoAnotherConversation() async throws {
    try await withSessionDeps {
      let harness = try await SessionHarness(dev: false)
      let (aliceBearer, aliceKey) = try await harness.enrolledBearer()
      let (bobBearer, bobKey) = try await harness.enrolledBearer()
      let alice = try await harness.space.mintPersona(key: aliceKey).name
      let bob = try await harness.space.mintPersona(key: bobKey).name
      let destination = try await harness.store.createConversation(members: [bob], in: .shared)
      let foreign = try await harness.space.ensurePersonalGroup(account: harness.space.addAccount(kind: .human, name: nil).id)
      try await harness.space.addEdge(src: .shared, dst: foreign, kind: .read, by: nil)
      for group in [GroupID.shared, foreign] {
        let source = try await harness.store.createConversation(members: [alice, bob], in: group)
        let delivery = try await harness.store.post(.conversation(source), messageID: MessageID("copy-source-" + group.rawValue), sender: Sender(id: alice, timeZone: .gmt), content: .init(text: "private"), uploads: [AttachmentUpload(name: "secret.txt", bytes: Array("secret".utf8))])
        let path = try #require(delivery.message.content.attachments.first?.path)
        let qualified = "wuhu://\(group.rawValue).localspace" + path
        let references = group == .shared ? [path, qualified] : [qualified]
        for reference in references {
          let fields: JSONValue = ["conversation": .string(destination.rawValue), "message": "copy", "attachments": .array([.string(reference)])]
          let allowed = try await harness.post("/v1/conversation/message", fields, bearer: bobBearer)
          #expect(allowed.status == .ok)
        }
        try await harness.store.removeChannelMembers(source, people: [bob], as: Principal(actor: .person(persona: alice, account: aliceKey.account), group: group))
        let count = try await harness.store.messages(conversation: destination).count
        for reference in references {
          let fields: JSONValue = ["conversation": .string(destination.rawValue), "message": "leak", "attachments": .array([.string(reference)])]
          let refused = try await harness.post("/v1/conversation/message", fields, bearer: bobBearer)
          #expect(refused.status == .notFound)
          #expect(try await json(refused).object?["code"] == "notFound")
        }
        #expect(try await harness.store.messages(conversation: destination).count == count)
        #expect(try await harness.get("/v1/f" + path, query: ["group": group.rawValue], bearer: aliceBearer).status == .ok)
      }
    }
  }

  @Test func removingAMemberClosesAnAlreadyOpenConversationSSE() async throws {
    try await withSessionDeps {
      let harness = try await SessionHarness()
      let alice = try await harness.mintPersona()
      let (bobBearer, bobKey) = try await harness.enrolledBearer()
      let bob = try await harness.space.mintPersona(key: bobKey).name
      let id = try await harness.store.createConversation(members: [alice, bob], in: .shared)
      _ = try await harness.store.post(.conversation(id), messageID: MessageID("before"), sender: Sender(id: alice, timeZone: .gmt), content: .init(text: "before"))
      let response = try await harness.get("/v1/conversation/\(id.rawValue)/observe", bearer: bobBearer)
      #expect(response.status == .ok)
      var events = response.sse().makeAsyncIterator()
      let initial = try #require(try await events.next())
      #expect(initial.data.contains("before"))
      try await harness.store.removeChannelMembers(id, people: [bob], as: .shared(.person(persona: alice, account: AccountID(rawValue: "alice"))))
      _ = try await harness.store.post(.conversation(id), messageID: MessageID("after"), sender: Sender(id: alice, timeZone: .gmt), content: .init(text: "after"))
      #expect(try await events.next() == nil)
      #expect(try await harness.get("/v1/conversation/\(id.rawValue)/observe", bearer: bobBearer).status == .notFound)
    }
  }

  @Test func devAnonymousReadAndManagementAreRefusedAndMembersListRecentActivity() async throws {
    try await withSessionDeps {
      let harness = try await SessionHarness()
      let (aliceBearer, aliceKey) = try await harness.enrolledBearer()
      let alice = try await harness.space.mintPersona(key: aliceKey).name
      let first = try await harness.store.createConversation(members: [alice, ownerIdentity], title: "First", in: .shared)
      let second = try await harness.store.createConversation(members: [alice], title: "Second", in: .shared)
      for (operation, fields) in [("rename", JSONValue.object(["title": "First renamed"])), ("add", ["people": .array([.string(alice)])]), ("remove", ["people": .array([.string(alice)])])] {
        let response = try await harness.post("/v1/channel/\(first.rawValue)/" + operation, fields)
        #expect(response.status == .notFound)
        #expect(try await json(response).object?["code"] == "notFound")
      }
      #expect(try await harness.get("/v1/conversation/\(first.rawValue)/messages").status == .notFound)
      #expect(try await harness.get("/v1/conversation/\(first.rawValue)/messages", query: ["identity": alice]).status == .notFound)
      for fields in [JSONValue.object(["members": .array([.string(alice)])]), ["members": .array([.string(alice)]), "identity": .string(alice)]] {
        let response = try await harness.post("/v1/conversation", fields)
        #expect(response.status == .badRequest)
        let error = try await json(response)
        #expect(error.object?["code"] == "invalidArgument")
        #expect(error.object?["message"] == "creating a channel needs an identified person or session")
      }
      let created = try await harness.call("/v1/conversation", ["members": .array([]), "title": "Identified"], as: ConversationPostOutput.self, bearer: aliceBearer)
      #expect(try await harness.store.conversation(ConversationID(created.conversationId)).members.map(\.member) == [alice])
      for (id, message) in [(second, "second"), (first, "first")] {
        _ = try await harness.store.post(.conversation(id), messageID: MessageID(message), sender: Sender(id: alice, timeZone: .gmt), content: .init(text: message))
      }
      let anonymous = try await harness.get("/v1/conversations")
      #expect(try await anonymous.json(ConversationsOutput.self).conversations.isEmpty)
      let response = try await harness.get("/v1/conversations", bearer: aliceBearer)
      let rows = try await response.json(ConversationsOutput.self)
      #expect(rows.conversations.prefix(2).map(\.id) == [first.rawValue, second.rawValue])
    }
  }
}
