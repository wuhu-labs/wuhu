import DeterministicDependencies
import Fetch
import FetchSSE
import Foundation
import JSONValue
import SessionDomain
import SpaceContract
@testable import SpaceCore
import struct SpaceIDs.AccountID
import struct SpaceIDs.ConversationID
import struct SpaceIDs.GroupID
import struct SpaceIDs.MessageID
@testable import SpaceServer
import Testing

@Suite(.deterministicDependencies) struct ChannelReadRouteTests {
  @Test func attachmentsRequireMembershipAcrossFileToolsListingsAndContentHosts() async throws {
    try await withSessionDeps {
      let harness = try await SessionHarness(dev: false, origin: "https://localhost")
      let (aliceBearer, aliceKey) = try await harness.enrolledBearer()
      let (carolBearer, carolKey) = try await harness.enrolledBearer()
      let alice = try await harness.space.adoptPersona(key: aliceKey).name
      _ = try await harness.space.adoptPersona(key: carolKey)
      let aliceCookie = try await harness.space.createReadSession(account: aliceKey.account, group: .shared, expiresAt: Date().addingTimeInterval(3600))
      let carolCookie = try await harness.space.createReadSession(account: carolKey.account, group: .shared, expiresAt: Date().addingTimeInterval(3600))
      let foreign = GroupID(rawValue: "project")
      try RawDatabase.open(harness.space.databasePath) { db in
        try db.execute(sql: "INSERT INTO groups (id, created_at) VALUES ('project', '2026-01-01T00:00:00Z')")
      }
      try await harness.space.setGrant(.group, GroupID.shared.rawValue, role: .write, in: foreign, by: (try await harness.space.ensureDevPerson()).actor, acting: foreign)
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
      let alice = try await harness.space.adoptPersona(key: aliceKey).name
      let bob = try await harness.space.adoptPersona(key: bobKey).name
      let destination = try await harness.store.createConversation(members: [bob], in: .shared)
      let foreign = GroupID(rawValue: "project")
      try RawDatabase.open(harness.space.databasePath) { db in
        try db.execute(sql: "INSERT INTO groups (id, created_at) VALUES ('project', '2026-01-01T00:00:00Z')")
      }
      try await harness.space.setGrant(.group, GroupID.shared.rawValue, role: .write, in: foreign, by: (try await harness.space.ensureDevPerson()).actor, acting: foreign)
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
      let alice = try await harness.space.ensureDevPerson().persona
      let (bobBearer, bobKey) = try await harness.enrolledBearer()
      let bob = try await harness.space.adoptPersona(key: bobKey).name
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

  @Test func theDevPersonCannotImpersonateChannelMembers() async throws {
    try await withSessionDeps {
      let harness = try await SessionHarness()
      let (aliceBearer, aliceKey) = try await harness.enrolledBearer()
      let alice = try await harness.space.adoptPersona(key: aliceKey).name
      let bob = try await harness.adoptPersona()
      _ = try await harness.space.setUserProfile(principal: bob, handle: "bob", displayName: nil)
      let first = try await harness.store.createConversation(members: [alice, bob], title: "First", in: .shared)
      let second = try await harness.store.createConversation(members: [alice], title: "Second", in: .shared)
      for (operation, fields) in [("rename", JSONValue.object(["title": "First renamed"])), ("add", ["people": .array([.string(alice)])]), ("remove", ["people": .array([.string(alice)])])] {
        let response = try await harness.post("/v1/channel/\(first.rawValue)/" + operation, fields)
        #expect(response.status == .notFound)
        #expect(try await json(response).object?["code"] == "notFound")
      }
      #expect(try await harness.get("/v1/conversation/\(first.rawValue)/messages").status == .notFound)
      #expect(try await harness.get("/v1/conversation/\(first.rawValue)/messages", query: ["identity": alice]).status == .forbidden)
      let devCreated = try await harness.call("/v1/conversation", ["members": .array([.string(alice)])], as: ConversationPostOutput.self)
      let dev = try await harness.space.ensureDevPerson()
      #expect(try await harness.store.conversation(ConversationID(devCreated.conversationId)).members.map(\.member).contains(dev.persona))
      let impersonated = try await harness.post("/v1/conversation", ["members": .array([.string(alice)]), "identity": .string(alice)])
      #expect(impersonated.status == .forbidden)
      #expect(try await json(impersonated).object?["code"] == "identityNotYours")
      let created = try await harness.call("/v1/conversation", ["members": .array([]), "title": "Identified"], as: ConversationPostOutput.self, bearer: aliceBearer)
      #expect(try await harness.store.conversation(ConversationID(created.conversationId)).members.map(\.member) == [alice])
      #expect(try await harness.get("/v1/conversation/\(devCreated.conversationId)").status == .ok)
      #expect(try await harness.get("/v1/conversation/\(first.rawValue)", bearer: aliceBearer).status == .ok)
      #expect(try await harness.get("/v1/conversation/\(second.rawValue)", bearer: aliceBearer).status == .ok)
      #expect(try await harness.get("/v1/conversation/\(first.rawValue)").status == .notFound)
      #expect(try await harness.get("/v1/conversation/\(created.conversationId)").status == .notFound)
    }
  }

  @Test func aConversationDetailAnswersKindAndMembersToItsReader() async throws {
    try await withSessionDeps {
      let harness = try await SessionHarness()
      let (aliceBearer, aliceKey) = try await harness.enrolledBearer()
      let alice = try await harness.space.adoptPersona(key: aliceKey).name
      let bob = try await harness.adoptPersona()
      let id = try await harness.store.createConversation(members: [alice, bob], in: .shared)

      let read = try await harness.get("/v1/conversation/\(id.rawValue)", bearer: aliceBearer)
      #expect(read.status == .ok)
      let detail = try await read.json(ConversationDetail.self)
      #expect(detail.kind == .users)
      #expect(Set(detail.members.map(\.member)) == [alice, bob])
      #expect(detail.members.allSatisfy { $0.kind == "user" })

      let unreadable = try await harness.get("/v1/conversation/\(id.rawValue)")
      #expect(unreadable.status == .notFound)
      #expect(try await json(unreadable).object?["code"] == "notFound")

      let unknown = try await harness.get("/v1/conversation/nowhere")
      #expect(unknown.status == .notFound)
      #expect(try await json(unknown).object?["code"] == "notFound")

      // Readable by its home group, but the dev seat is no member: the list would never have named it.
      let carol = try await harness.adoptPersona()
      let dave = try await harness.adoptPersona()
      let dm = try await harness.store.post(
        .dm(with: dave), messageID: MessageID("between-two-others"), sender: Sender(id: carol, timeZone: .gmt),
        content: .init(text: "hi"), acting: Principal(actor: .publicReader, group: .shared),
      )
      #expect(try await harness.get("/v1/conversation/\(dm.message.conversation.rawValue)/messages").status == .ok)
      #expect(try await harness.get("/v1/conversation/\(dm.message.conversation.rawValue)").status == .notFound)
    }
  }
}
