import Assertion
import Crypto
import Fetch
import Foundation
import JSONValue
import SessionDomain
import SpaceContract
import SpaceCore
import Testing

@Suite struct SessionRoutesTests {
  @Test func createValidatesTheModelSpecifier() async throws {
    try await withSessionDeps {
      let harness = try await SessionHarness()

      let unknownProvider = try await harness.post(
        "/v1/session", .object(["kind": "agent", "title": "t", "provider": "nope", "model": "test-model"]),
      )
      #expect(unknownProvider.status == .unprocessableContent)

      let unknownEffort = try await harness.post(
        "/v1/session",
        .object(["kind": "agent", "title": "t", "provider": "testing", "model": "test-model", "effort": "ultra"]),
      )
      #expect(unknownEffort.status == .unprocessableContent)

      let created = try await harness.call(
        "/v1/session",
        .object(["kind": "agent", "title": "worker", "provider": "testing", "model": "test-model", "tags": .array(["a"])]),
        as: SessionCreateOutput.self,
      )
      #expect(created.effort == "high")
      let record = try await harness.store.record(SessionID(created.id))
      #expect(record.title == "worker")
      #expect(record.tags == ["a"])
      #expect(record.createdBy == "owner")
      #expect(record.executor == .kernel(ModelSpecifier(provider: "testing", model: "test-model", effort: "high")))
    }
  }

  @Test func claudeDialectCreatesAKernelSession() async throws {
    try await withSessionDeps {
      let harness = try await SessionHarness()
      _ = try await harness.space.fs(.shared).write("/models.json", Data("""
      {"claude": {"dialect": "claude", "baseURL": "https://api.anthropic.com/v1",
        "models": {"opus": {"maxInput": 1000000, "maxOutput": 32000,
          "efforts": ["high"], "defaultEffort": "high"}}}}
      """.utf8), ifMatch: nil)
      let response = try await harness.post(
        "/v1/session", .object(["kind": "agent", "title": "t", "provider": "claude", "model": "opus"]),
      )
      #expect(response.status == .ok)
      let id = try #require(JSONValue.parse(try await response.text())?.object?["id"]?.stringValue)
      #expect(try await harness.store.record(SessionID(id)).executor == .kernel(ModelSpecifier(provider: "claude", model: "opus", effort: "high")))
    }
  }

  @Test func createWithoutModelsDataFailsLoudly() async throws {
    try await withSessionDeps {
      let harness = try await SessionHarness(models: false)
      let response = try await harness.post(
        "/v1/session", .object(["kind": "agent", "title": "t", "provider": "testing", "model": "test-model"]),
      )
      #expect(response.status == .unprocessableContent)
    }
  }

  @Test func verbsRoundTripTheStateAxes() async throws {
    try await withSessionDeps {
      let harness = try await SessionHarness { _, _ in reply("ok") }
      let id = try await harness.createSession()

      _ = try await harness.call("/v1/session/\(id.rawValue)/interrupt", .null, as: [String: String].self)
      let interrupted = try await harness.store.record(id)
      #expect(interrupted.hold == .interrupted)

      _ = try await harness.call("/v1/session/\(id.rawValue)/resume", .null, as: [String: String].self)
      let resumed = try await harness.store.record(id)
      #expect(resumed.hold == .normal)

      // A created session's head carries nothing forward, so materializing it
      // is not work and archive needs no settle to wait for.
      _ = try await harness.call("/v1/session/\(id.rawValue)/archive", .null, as: [String: String].self)
      guard case .archived = try await harness.store.record(id).lifecycle else {
        Issue.record("expected archived lifecycle")
        return
      }

      _ = try await harness.call("/v1/session/\(id.rawValue)/unarchive", .null, as: [String: String].self)
      let unarchived = try await harness.store.record(id)
      #expect(unarchived.lifecycle == .live)

      let missing = try await harness.post("/v1/session/\(UUID().uuidString.lowercased())/interrupt", .null)
      #expect(missing.status == .notFound)
    }
  }

  @Test func channelPostReturnsTheCreatedThreadAndReadsPageByCursor() async throws {
    try await withSessionDeps {
      let harness = try await SessionHarness()
      let id = try await harness.createSession()
      let key = id.rawValue

      let alice = try await harness.mintPersona()
      let bob = try await harness.mintPersona()
      let head = try await harness.call(
        "/v1/conversation/message",
        .object(["message": "first", "session": .string(key), "identity": .string(alice), "timezone": "Europe/Paris"]),
        as: ConversationPostOutput.self,
      )
      #expect(head.conversationId == key)

      _ = try await harness.call(
        "/v1/conversation/message",
        .object(["message": "second", "session": .string(key), "identity": .string(alice)]),
        as: ConversationPostOutput.self,
      )
      let threadReply = try await harness.call(
        "/v1/conversation/message",
        .object(["message": "third", "replyTarget": .string(head.messageId), "session": .string(key), "identity": .string(bob)]),
        as: ConversationPostOutput.self,
      )
      #expect(threadReply.conversationId == head.conversationId)

      let all = try JSONValueDecoder().decode(
        ConversationReadOutput.self,
        from: try await json(try await harness.get("/v1/conversation/\(key)/messages")),
      )
      #expect(all.messages.map(\.text) == ["first", "second", "third"])
      #expect(all.messages[0].sender == alice)
      #expect(all.messages[0].senderTimezone == "Europe/Paris")

      let afterFirst = try JSONValueDecoder().decode(
        ConversationReadOutput.self,
        from: try await json(try await harness.get("/v1/conversation/\(key)/messages", query: ["after": String(all.messages[0].n)])),
      )
      #expect(afterFirst.messages.map(\.text) == ["second", "third"])

      let both = try await harness.post(
        "/v1/conversation/message",
        .object(["message": "x", "session": .string(key), "user": .string(alice)]),
      )
      #expect(both.status == .badRequest)
    }
  }

  @Test func conversationMessagesForAnUnknownConversationAre404() async throws {
    try await withSessionDeps {
      let harness = try await SessionHarness()
      let junk = try await harness.get("/v1/conversation/no-such-session/messages")
      #expect(junk.status == .notFound)
    }
  }

  @Test func notificationsReadAndWatermarkAdvance() async throws {
    try await withSessionDeps {
      let harness = try await SessionHarness()
      let id = try await harness.createSession()
      let key = id.rawValue

      let alice = try await harness.mintPersona()
      let bob = try await harness.mintPersona()
      let head = try await harness.call(
        "/v1/conversation/message",
        .object(["message": "question", "session": .string(key), "identity": .string(alice)]),
        as: ConversationPostOutput.self,
      )
      _ = try await harness.call(
        "/v1/conversation/message",
        .object(["message": "answer", "replyTarget": .string(head.messageId), "session": .string(key), "identity": .string(bob)]),
        as: ConversationPostOutput.self,
      )

      let inbox = try JSONValueDecoder().decode(
        NotificationsOutput.self,
        from: try await json(try await harness.get("/v1/notifications", query: ["identity": alice])),
      )
      #expect(inbox.notifications.count == 1)
      let notification = try #require(inbox.notifications.first)
      #expect(notification.kind == .conversationMessage)
      #expect(notification.recipient == alice)
      #expect(notification.group == "shared", "each row names its group: one inbox spans them")

      let above = try JSONValueDecoder().decode(
        NotificationsOutput.self,
        from: try await json(try await harness.get(
          "/v1/notifications", query: ["identity": alice, "after": String(notification.n)],
        )),
      )
      #expect(above.notifications.isEmpty)

      let watermark = try await harness.call(
        "/v1/watermark",
        .object(["source": .string(notification.source), "identity": .string(alice)]),
        as: WatermarkOutput.self,
      )
      #expect(watermark.lastReadN >= notification.n)
    }
  }

  @Test func freeFormIdentitiesAreRejectedBeforeTheyCanAct() async throws {
    try await withSessionDeps {
      let harness = try await SessionHarness()
      let id = try await harness.createSession()
      let key = id.rawValue

      // The squat this closes: a free-form identity equal to a session's
      // word-name would get broadcast replies enqueued into that session.
      for identity in [key, "silverstone-alpine-leclerc"] {
        let post = try await harness.post(
          "/v1/conversation/message",
          .object(["message": "hi", "session": .string(key), "identity": .string(identity)]),
        )
        #expect(post.status == .forbidden)
        let error = try await json(post)
        #expect(error.object?["code"]?.stringValue == "unknownIdentity")
        #expect(error.object?["message"]?.stringValue?.contains(identity) == true)
      }

      let create = try await harness.post(
        "/v1/session",
        .object(["kind": "agent", "title": "t", "provider": "testing", "model": "test-model", "identity": "squatter"]),
      )
      #expect(create.status == .forbidden)

      let notifications = try await harness.get("/v1/notifications", query: ["identity": "squatter"])
      #expect(notifications.status == .forbidden)

      let watermark = try await harness.post(
        "/v1/watermark",
        .object(["source": "s", "identity": "squatter"]),
      )
      #expect(watermark.status == .forbidden)

      // The owner principal needs no persona, spelled out or implied.
      let owner = try await harness.call(
        "/v1/conversation/message",
        .object(["message": "mine", "session": .string(key), "identity": "owner"]),
        as: ConversationPostOutput.self,
      )
      #expect(owner.conversationId == key)
    }
  }

  @Test func aWalledServerNeverAttributesTheGenericOwner() async throws {
    try await withSessionDeps {
      let harness = try await SessionHarness(dev: false)
      let (bearer, enrolled) = try await harness.enrolledBearer()
      let persona = try await harness.space.mintPersona(key: enrolled).name

      let created = try await harness.call(
        "/v1/session",
        .object(["kind": "agent", "title": "t", "provider": "testing", "model": "test-model", "identity": .string(persona)]),
        as: SessionCreateOutput.self,
        bearer: bearer,
      )
      #expect(try await harness.store.record(SessionID(created.id)).createdBy == persona)

      // The spelled-out owner stays inert on every attributed route, even for
      // a verified bearer.
      let probes: [(String, JSONValue)] = [
        ("/v1/session", .object(["kind": "agent", "title": "t", "provider": "testing", "model": "test-model"])),
        ("/v1/conversation/message", .object(["message": "hi", "session": .string(created.id)])),
        ("/v1/watermark", .object(["source": "s"])),
      ]
      for (path, body) in probes {
        var fields = body.object!
        fields["identity"] = "owner"
        let response = try await harness.post(path, .object(fields), bearer: bearer)
        #expect(response.status == .forbidden, "\(path)")
        let error = try await json(response)
        #expect(error.object?["code"]?.stringValue == "ownerIdentityWalled", "\(path)")
      }
      let notifications = try await harness.get("/v1/notifications", query: ["identity": "owner"], bearer: bearer)
      #expect(notifications.status == .forbidden)
      let error = try await json(notifications)
      #expect(error.object?["code"]?.stringValue == "ownerIdentityWalled")

      let posted = try await harness.call(
        "/v1/conversation/message",
        .object(["message": "hi", "session": .string(created.id), "identity": .string(persona)]),
        as: ConversationPostOutput.self,
        bearer: bearer,
      )
      let entries = try JSONValueDecoder().decode(
        ConversationReadOutput.self,
        from: try await json(try await harness.get("/v1/conversation/\(created.id)/messages", bearer: bearer)),
      )
      #expect(entries.messages.map(\.messageId) == [posted.messageId])
      #expect(entries.messages.map(\.sender) == [persona])
    }
  }

  @Test func aWalledServerDerivesTheActorFromTheBearer() async throws {
    try await withSessionDeps {
      let harness = try await SessionHarness(dev: false)
      let (bearer, enrolled) = try await harness.enrolledBearer()
      #expect(try await harness.space.persona(account: enrolled.account) == nil)

      let created = try await harness.call(
        "/v1/session",
        .object(["kind": "agent", "title": "t", "provider": "testing", "model": "test-model"]),
        as: SessionCreateOutput.self,
        bearer: bearer,
      )
      let persona = try #require(try await harness.space.persona(account: enrolled.account)).name
      #expect(try await harness.store.record(SessionID(created.id)).createdBy == persona)

      let first = try await harness.call(
        "/v1/conversation/message",
        .object(["message": "hello", "session": .string(created.id)]),
        as: ConversationPostOutput.self,
        bearer: bearer,
      )
      let second = try await harness.call(
        "/v1/conversation/message",
        .object(["message": "again", "session": .string(created.id)]),
        as: ConversationPostOutput.self,
        bearer: bearer,
      )
      let entries = try JSONValueDecoder().decode(
        ConversationReadOutput.self,
        from: try await json(try await harness.get("/v1/conversation/\(created.id)/messages", bearer: bearer)),
      )
      #expect(entries.messages.map(\.messageId) == [first.messageId, second.messageId])
      #expect(entries.messages.map(\.sender) == [persona, persona])

      // The read path derives the same way: a reply from another bearer lands
      // in this bearer's inbox with no identity spelled out anywhere.
      let (other, otherKey) = try await harness.enrolledBearer()
      _ = try await harness.call(
        "/v1/conversation/message",
        .object(["message": "reply", "session": .string(created.id), "replyTarget": .string(first.messageId)]),
        as: ConversationPostOutput.self,
        bearer: other,
      )
      let otherPersona = try #require(try await harness.space.persona(account: otherKey.account)).name
      #expect(otherPersona != persona)
      let inbox = try JSONValueDecoder().decode(
        NotificationsOutput.self,
        from: try await json(try await harness.get("/v1/notifications", bearer: bearer)),
      )
      #expect(inbox.notifications.count == 1)
      #expect(inbox.notifications.first?.recipient == persona)
    }
  }

  @Test func aBearerCannotActAsAnotherAccountsPersona() async throws {
    try await withSessionDeps {
      let harness = try await SessionHarness(dev: false)
      let (alice, aliceKey) = try await harness.enrolledBearer()
      let (bob, bobKey) = try await harness.enrolledBearer()
      let alicePersona = try await harness.space.mintPersona(key: aliceKey).name
      let bobPersona = try await harness.space.mintPersona(key: bobKey).name

      let created = try await harness.call(
        "/v1/session",
        .object(["kind": "agent", "title": "t", "provider": "testing", "model": "test-model", "identity": .string(alicePersona)]),
        as: SessionCreateOutput.self,
        bearer: alice,
      )

      let forged = try await harness.post(
        "/v1/conversation/message",
        .object(["message": "as alice", "session": .string(created.id), "identity": .string(alicePersona)]),
        bearer: bob,
      )
      #expect(forged.status == .forbidden)
      let error = try await json(forged)
      #expect(error.object?["code"]?.stringValue == "identityNotYours")
      #expect(error.object?["message"]?.stringValue?.contains(alicePersona) == true)

      let entries = try JSONValueDecoder().decode(
        ConversationReadOutput.self,
        from: try await json(try await harness.get("/v1/conversation/\(created.id)/messages", bearer: alice)),
      )
      #expect(entries.messages.isEmpty)

      let inbox = try await harness.get("/v1/notifications", query: ["identity": alicePersona], bearer: bob)
      #expect(inbox.status == .forbidden)
      #expect((try await json(inbox)).object?["code"]?.stringValue == "identityNotYours")

      let owned = try await harness.call(
        "/v1/conversation/message",
        .object(["message": "as bob", "session": .string(created.id), "identity": .string(bobPersona)]),
        as: ConversationPostOutput.self,
        bearer: bob,
      )
      let after = try JSONValueDecoder().decode(
        ConversationReadOutput.self,
        from: try await json(try await harness.get("/v1/conversation/\(created.id)/messages", bearer: alice)),
      )
      #expect(after.messages.map(\.messageId) == [owned.messageId])
      #expect(after.messages.map(\.sender) == [bobPersona])
    }
  }

  @Test func accountPersonasAreInterchangeableAcrossItsKeys() async throws {
    try await withSessionDeps {
      let harness = try await SessionHarness(dev: false)
      let (_, firstKey) = try await harness.enrolledBearer()
      let persona = try await harness.space.mintPersona(key: firstKey).name
      let (second, _) = try await harness.enrolledBearer(account: firstKey.account)

      // Explicit: another key of the same account may speak as its persona.
      let created = try await harness.call(
        "/v1/session",
        .object(["kind": "agent", "title": "t", "provider": "testing", "model": "test-model", "identity": .string(persona)]),
        as: SessionCreateOutput.self,
        bearer: second,
      )
      #expect(try await harness.store.record(SessionID(created.id)).createdBy == persona)

      // Derived: a different key of the same account converges onto the
      // account's earliest persona instead of minting a second one.
      let posted = try await harness.call(
        "/v1/conversation/message",
        .object(["message": "hi", "session": .string(created.id)]),
        as: ConversationPostOutput.self,
        bearer: second,
      )
      let entries = try JSONValueDecoder().decode(
        ConversationReadOutput.self,
        from: try await json(try await harness.get("/v1/conversation/\(created.id)/messages", bearer: second)),
      )
      #expect(entries.messages.map(\.messageId) == [posted.messageId])
      #expect(entries.messages.map(\.sender) == [persona])
    }
  }

  @Test func aVerifiedBearerInDevModeResolvesLikeWalled() async throws {
    try await withSessionDeps {
      let harness = try await SessionHarness()
      let (bearer, enrolled) = try await harness.enrolledBearer()

      let created = try await harness.call(
        "/v1/session",
        .object(["kind": "agent", "title": "t", "provider": "testing", "model": "test-model"]),
        as: SessionCreateOutput.self,
        bearer: bearer,
      )
      let persona = try #require(try await harness.space.persona(account: enrolled.account)).name
      #expect(persona != "owner")
      #expect(try await harness.store.record(SessionID(created.id)).createdBy == persona)

      let stranger = try await harness.mintPersona()
      let forged = try await harness.post(
        "/v1/conversation/message",
        .object(["message": "hi", "session": .string(created.id), "identity": .string(stranger)]),
        bearer: bearer,
      )
      #expect(forged.status == .forbidden)
      #expect((try await json(forged)).object?["code"]?.stringValue == "identityNotYours")
    }
  }

  @Test func aRejectedBearerIsRefusedEvenInDevMode() async throws {
    try await withSessionDeps {
      let harness = try await SessionHarness()
      let unenrolled = Curve25519.Signing.PrivateKey()
      let bearer = try AssertionClaims(
        key: unenrolled.pubkeyLabel,
        space: try await harness.space.identity().rawValue,
        expiresAt: Date().addingTimeInterval(3600),
      ).signed(by: unenrolled).rawValue
      let response = try await harness.post(
        "/v1/session",
        .object(["kind": "agent", "title": "t", "provider": "testing", "model": "test-model"]),
        bearer: bearer,
      )
      #expect(response.status == .unauthorized)
    }
  }

  @Test func aContractorKeyCannotDeriveAPersona() async throws {
    try await withSessionDeps {
      let harness = try await SessionHarness(dev: false)
      let (bearer, _) = try await harness.enrolledBearer(capabilities: [.contractor])
      let response = try await harness.post(
        "/v1/session",
        .object(["kind": "agent", "title": "t", "provider": "testing", "model": "test-model"]),
        bearer: bearer,
      )
      #expect(response.status == .forbidden)
      #expect((try await json(response)).object?["code"]?.stringValue == "personaRequiresDevice")
    }
  }

  @Test func sessionRoutesStayBehindTheAuthGate() async throws {
    try await withSessionDeps {
      let harness = try await SessionHarness(dev: false)
      let response = try await harness.post(
        "/v1/session", .object(["kind": "agent", "title": "t", "provider": "testing", "model": "test-model"]),
      )
      #expect(response.status == .unauthorized)
      let notifications = try await harness.get("/v1/notifications")
      #expect(notifications.status == .unauthorized)
    }
  }
}

extension SessionHarness {
  func enrolledBearer(
    account: AccountID? = nil,
    capabilities: Set<KeyCapability> = [.device],
  ) async throws -> (bearer: String, key: KeyRecord) {
    let signing = Curve25519.Signing.PrivateKey()
    let owner: AccountID
    if let account {
      owner = account
    } else {
      owner = try await space.addAccount(kind: .human, name: nil).id
    }
    let enrolled = try await space.addKey(
      signing.pubkeyLabel, account: owner, capabilities: capabilities, createdBy: nil, expiresAt: nil,
    )
    let bearer = try AssertionClaims(
      key: signing.pubkeyLabel,
      space: try await space.identity().rawValue,
      expiresAt: Date().addingTimeInterval(3600),
    ).signed(by: signing).rawValue
    return (bearer, enrolled)
  }
}

@Suite struct HistoryRoutesTests {
  @Test func historyIsAdditiveAuthorizedAndValidatesItsCursor() async throws {
    try await withSessionDeps {
      let harness = try await SessionHarness()
      let id = try await harness.createSession()
      let bounded = try await harness.get("/v1/session/\(id.rawValue)/transcript/page")
      #expect(bounded.status == .ok)
      let page = try await bounded.json(TranscriptHistoryOutput.self)
      #expect(page.entries.count <= 200)
      #expect(!page.hasEarlier)
      let legacy = try await harness.get("/v1/session/\(id.rawValue)/transcript")
      #expect(try await legacy.json(TranscriptReadOutput.self).items.count == page.entries.count)
      let invalid = try await harness.get("/v1/session/\(id.rawValue)/transcript/page", query: ["before": "1"])
      #expect(invalid.status == .badRequest)
      let over = try await harness.get("/v1/session/\(id.rawValue)/transcript/page", query: ["limit": "201"])
      #expect(over.status == .badRequest)
      let before = page.generation
      _ = try await harness.store.restart(id)
      let stale = try await harness.get("/v1/session/\(id.rawValue)/transcript/page", query: ["generation": String(before), "before": "0"])
      #expect(stale.status == .conflict)
      #expect(JSONValue.parse(try await stale.text())?.object?["code"] == "generationChanged")
    }
  }
}

@Suite struct ClaudeHistoryRoutesTests {}

@Suite struct ConversationHistoryRoutesTests {
  @Test func sparseOrdinalsUseExtraRowExhaustionAndExclusiveBoundaries() async throws {
    try await withSessionDeps {
      let harness = try await SessionHarness()
      let id = try await harness.createSession()
      let other = try await harness.createSession()
      for index in 0 ..< 5 {
        _ = try await harness.call("/v1/conversation/message", .object(["message": .string("entry \(index)"), "session": .string(id.rawValue)]), as: ConversationPostOutput.self)
        _ = try await harness.call("/v1/conversation/message", .object(["message": "unrelated", "session": .string(other.rawValue)]), as: ConversationPostOutput.self)
      }
      let path = "/v1/conversation/\(id.rawValue)/messages"
      let response = try await harness.get(path, query: ["tail": "2", "paged": "true"])
      let tail = try await response.json(ConversationHistoryOutput.self)
      #expect(tail.messages.map(\.text) == ["entry 3", "entry 4"])
      #expect(tail.hasEarlier)
      #expect(tail.headPosition == tail.messages.last?.n)
      let middleResponse = try await harness.get(path, query: ["tail": "2", "paged": "true", "before": String(try #require(tail.before))])
      let middle = try await middleResponse.json(ConversationHistoryOutput.self)
      #expect(middle.messages.map(\.text) == ["entry 1", "entry 2"])
      #expect(middle.hasEarlier)
      let firstResponse = try await harness.get(path, query: ["tail": "2", "paged": "true", "before": String(try #require(middle.before))])
      let first = try await firstResponse.json(ConversationHistoryOutput.self)
      #expect(first.messages.map(\.text) == ["entry 0"])
      #expect(!first.hasEarlier)
      let legacy = try await harness.get(path, query: ["tail": "2"])
      #expect(try await legacy.json(ConversationReadOutput.self).messages == tail.messages)
    }
  }

  @Test func pagedReadsRemainBehindAuthentication() async throws {
    try await withSessionDeps {
      let harness = try await SessionHarness(dev: false)
      let id = try await harness.store.createSession(group: .shared, title: "private", kind: .agent, createdBy: "owner", model: ModelSpecifier(provider: "testing", model: "test-model", effort: "high"))
      let transcript = try await harness.get("/v1/session/\(id.rawValue)/transcript/page")
      #expect(transcript.status == .unauthorized)
      let conversation = try await harness.get("/v1/conversation/\(id.rawValue)/messages", query: ["tail": "100", "paged": "true"])
      #expect(conversation.status == .unauthorized)
    }
  }
}
