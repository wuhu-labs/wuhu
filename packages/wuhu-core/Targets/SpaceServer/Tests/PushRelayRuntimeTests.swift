import Dependencies
import Fetch
import Foundation
import Logging
import SessionDomain
import SpaceCore
@testable import SpaceServer
import Testing

@Suite struct PushRelayRuntimeTests {
  @Test func aDeliveredNotificationCarriesTheRoutingDataATapNeeds() async throws {
    let messages = MessageCollector()
    let (space, owner) = try await relaySpace(grants: ["g1_live"])

    try await withDependencies {
      $0.date = .constant(fixedDate)
    } operation: {
      try await PushRelayRuntime(
        space: space,
        logger: Logger(label: "push-relay-test"),
        client: PushRelayClient { await messages.append($0) },
      ).drain()
    }

    let message = try #require(await messages.values.only)
    #expect(message.endpoint == "https://notifications.wuhu.ai/v1/push")
    #expect(message.token == "g1_live_secret")
    #expect(message.title == "helper")
    #expect(message.subtitle == "owner")
    #expect(message.body == "answer")
    #expect(message.data["kind"] == "conversation_message")
    // The conversation is what the outbox names; the session is what the app
    // can open. Both travel, and the second is the one a tap uses.
    #expect(message.data["conversation"] == message.data["source"])
    #expect(message.data["session"] == owner.rawValue)
    // The extension looks the sender up in the app's roster by id, so the id
    // travels with what kind of principal it is.
    let sender = try #require(message.data["sender"])
    #expect(try await space.sessions.record(SessionID(sender)).title == "helper")
    #expect(message.data["senderKind"] == "session")
    #expect(message.data["senderGroup"] == "shared")
    #expect(message.data["group"] == "shared")
    // Stable across retries: the outbox row number, not a fresh id per attempt.
    #expect(message.idempotencyKey == "g1_live:\(message.data["n"]!)")
    #expect(try await space.duePushRelayDeliveries(at: fixedDate).isEmpty)
  }

  // One inbox spans every group: a push names the notification's group, and a
  // sender from outside the conversation's group shows with theirs.
  @Test func anOutsideSenderIsTitledWithTheirGroup() async throws {
    let messages = MessageCollector()
    let (space, owner) = try await relaySpace(grants: ["g1_live"])
    try await withDependencies {
      $0.date = .constant(fixedDate)
    } operation: {
      let account = try await space.addAccount(kind: .human, name: "alice")
      let alice = try await space.ensurePersonalGroup(account: account.id)
      let visitor = try await space.sessions.createSession(
        group: alice, title: "visitor", kind: .agent, createdBy: "alice",
        model: ModelSpecifier(provider: "testing", model: "test-model", effort: "medium"),
      )
      _ = try await space.sessions.post(
        .box(owner),
        messageID: MessageID("visit"),
        sender: Sender(id: visitor.rawValue, timeZone: TimeZone(identifier: "UTC")!),
        senderSession: visitor,
        content: .init(text: "from outside"),
      )
      try await PushRelayRuntime(
        space: space,
        logger: Logger(label: "push-relay-test"),
        client: PushRelayClient { await messages.append($0) },
      ).drain()
      let inside = try #require(await messages.values.first { $0.body == "answer" })
      #expect(inside.title == "helper")
      let outside = try #require(await messages.values.first { $0.body == "from outside" })
      #expect(outside.title == "visitor (group \(alice.rawValue))")
      #expect(outside.data["group"] == "shared")
      #expect(outside.data["senderGroup"] == alice.rawValue)
    }
  }

  @Test func aPersonSendingIsAUserSender() async throws {
    let messages = MessageCollector()
    let (space, owner) = try await relaySpace(grants: ["g1_live"])
    try await withDependencies {
      $0.date = .constant(fixedDate)
    } operation: {
      let account = try await space.addAccount(kind: .human, name: nil)
      let key = try await space.addKey(
        testPubkey("other-device"),
        account: account.id,
        capabilities: [.device],
        createdBy: nil,
        expiresAt: nil,
      )
      let other = try await space.adoptPersona(key: key)
      _ = try await space.sessions.post(
        .box(owner),
        messageID: MessageID("aside"),
        sender: Sender(id: other.name, timeZone: TimeZone(identifier: "UTC")!),
        content: .init(text: "aside"),
      )
      try await PushRelayRuntime(
        space: space,
        logger: Logger(label: "push-relay-test"),
        client: PushRelayClient { await messages.append($0) },
      ).drain()
      let aside = try #require(await messages.values.first { $0.body == "aside" })
      #expect(aside.data["sender"] == other.name)
      #expect(aside.data["senderKind"] == "user")
    }
  }

  // The revocation contract: the device revokes at the gateway, the gateway
  // refuses with 410, and the grant stops existing here.
  @Test func aRevokedGrantIsDeletedAndStopsDelivering() async throws {
    let (space, _) = try await relaySpace(grants: ["g1_revoked", "g1_live"])

    try await withDependencies {
      $0.date = .constant(fixedDate)
    } operation: {
      try await PushRelayRuntime(
        space: space,
        logger: Logger(label: "push-relay-test"),
        client: PushRelayClient { message in
          guard message.token.hasPrefix("g1_revoked") else { return }
          throw PushRelayTransportError(status: 410, retryAfter: nil, underlying: "gone")
        },
      ).drain()
    }

    #expect(try await space.duePushRelayDeliveries(at: fixedDate).isEmpty)
    let surviving = try await space.pushRelayGrants(recipient: try #require(await onlyPersona(space)))
    #expect(surviving.map(\.grant) == ["g1_live"])
  }

  @Test func eachNotificationCollapsesAloneButOneConversationSharesAThread() async throws {
    let attempts = MessageCollector()
    let (space, owner) = try await relaySpace(grants: ["g1_live"])
    let helperRow = try await space.query("SELECT id FROM sessions WHERE title = 'helper'", as: .shared(.anonymous)).rows
    guard case let .text(helperID)? = helperRow.first?.first else { Issue.record("no helper"); return }
    let client = PushRelayClient { message in
      await attempts.append(message)
      if await attempts.values.count == 1 {
        throw PushRelayTransportError(status: 503, retryAfter: "30", underlying: "busy")
      }
    }

    for at in [fixedDate, fixedDate.addingTimeInterval(30)] {
      try await withDependencies {
        $0.date = .constant(at)
      } operation: {
        if at == fixedDate {
          _ = try await space.sessions.post(
            .box(owner), messageID: MessageID("second"),
            sender: Sender(id: helperID, timeZone: TimeZone(identifier: "UTC")!),
            senderSession: SessionID(helperID), content: .init(text: "second"),
          )
        }
        try await PushRelayRuntime(space: space, logger: Logger(label: "push-relay-test"), client: client).drain()
      }
    }

    let sent = await attempts.values
    try #require(sent.count == 3)
    let (failed, retried, second) = (sent[0], sent[1], sent[2])
    #expect(retried.collapseKey == failed.collapseKey)
    #expect(retried.collapseKey == "g1_live:\(retried.data["n"]!)")
    #expect(second.collapseKey == "g1_live:\(second.data["n"]!)")
    #expect(second.collapseKey != retried.collapseKey)
    #expect(second.data["conversation"] == retried.data["conversation"])
    #expect(second.threadID == retried.threadID)
    #expect(second.threadID == second.data["conversation"])
  }

  @Test func transientFailureDefersTheSameNotification() async throws {
    let (space, _) = try await relaySpace(grants: ["g1_retry"])
    try await withDependencies {
      $0.date = .constant(fixedDate)
    } operation: {
      try await PushRelayRuntime(
        space: space,
        logger: Logger(label: "push-relay-test"),
        client: PushRelayClient { _ in
          throw PushRelayTransportError(status: 503, retryAfter: "30", underlying: "busy")
        },
      ).drain()
    }

    #expect(try await space.duePushRelayDeliveries(at: fixedDate.addingTimeInterval(29)).isEmpty)
    let retried = try #require(try await space.duePushRelayDeliveries(at: fixedDate.addingTimeInterval(30)).only)
    #expect(retried.consecutiveFailures == 1)
    #expect(retried.notification.kind == .conversationMessage)
  }

  // A refusal of the payload is not a refusal of the grant: the notification is
  // abandoned, the grant keeps working.
  @Test func anUnsendablePayloadIsSkippedWithoutLosingTheGrant() async throws {
    let (space, _) = try await relaySpace(grants: ["g1_live"])
    try await withDependencies {
      $0.date = .constant(fixedDate)
    } operation: {
      try await PushRelayRuntime(
        space: space,
        logger: Logger(label: "push-relay-test"),
        client: PushRelayClient { _ in
          throw PushRelayTransportError(status: 413, retryAfter: nil, underlying: "payload_too_large")
        },
      ).drain()
    }

    #expect(try await space.duePushRelayDeliveries(at: fixedDate).isEmpty)
    let surviving = try await space.pushRelayGrants(recipient: try #require(await onlyPersona(space)))
    #expect(surviving.map(\.grant) == ["g1_live"])
  }

  @Test func aLongMessageIsClippedToWhatTheGatewayAccepts() async throws {
    let sent = LockIsolated<[Data]>([])
    let (space, owner) = try await relaySpace(grants: ["g1_live"])
    let text = String(repeating: "\"quoted\" 🦆 line\n", count: 400)

    try await withDependencies {
      $0.date = .constant(fixedDate)
    } operation: {
      _ = try await space.sessions.post(
        .box(owner),
        messageID: MessageID("long"),
        sender: Sender(id: owner.rawValue, timeZone: TimeZone(identifier: "UTC")!),
        senderSession: owner,
        content: .init(text: text),
      )
      try await PushRelayRuntime(
        space: space,
        logger: Logger(label: "push-relay-test"),
        client: .live(fetch: FetchClient { request in
          let body = try #require(try await request.body?.data())
          sent.withValue { $0.append(body) }
          return Response(status: .accepted)
        }),
      ).drain()
    }

    let envelope = try #require(sent.value.last)
    #expect(envelope.count < 4096)
    let notification = try #require(
      (try JSONSerialization.jsonObject(with: envelope) as? [String: Any])?["notification"] as? [String: Any],
    )
    #expect(notification["title"] as? String == "owner")
    #expect(notification["subtitle"] == nil)
    #expect(notification["badge"] as? Int == 1)
    let body = try #require(notification["body"] as? String)
    #expect(body.hasSuffix("…"))
    #expect(text.hasPrefix(body.dropLast()))
    #expect(jsonBytes(body) <= NotificationContent.bodyBytes)
    #expect(body.utf16.count <= 2048)
  }

  @Test func theBadgeCountsUnreadConversationsNotMessages() async throws {
    let messages = MessageCollector()
    let (space, owner) = try await relaySpace(grants: ["g1_live"])
    let persona = try #require(await onlyPersona(space))
    let helperRow = try await space.query("SELECT id FROM sessions WHERE title = 'helper'", as: .shared(.anonymous)).rows
    guard case let .text(helperID)? = helperRow.first?.first else { Issue.record("no helper"); return }
    let helper = SessionID(helperID)
    let utc = TimeZone(identifier: "UTC")!
    let runtime = PushRelayRuntime(
      space: space,
      logger: Logger(label: "push-relay-test"),
      client: PushRelayClient { await messages.append($0) },
    )

    try await withDependencies {
      $0.date = .constant(fixedDate)
    } operation: {
      _ = try await space.sessions.post(
        .box(helper), messageID: MessageID("q2"), sender: Sender(id: persona, timeZone: utc), content: .init(text: "q2"),
      )
      for (box, id) in [(helper, "a2"), (owner, "a3")] {
        _ = try await space.sessions.post(
          .box(box), messageID: MessageID(id), sender: Sender(id: helper.rawValue, timeZone: utc),
          senderSession: helper, content: .init(text: id),
        )
      }
      try await runtime.drain()
      #expect(await messages.values.map(\.badge) == [2, 2, 2])

      try await space.sessions.advanceWatermark(identity: persona, source: owner.rawValue)
      _ = try await space.sessions.post(
        .box(helper), messageID: MessageID("a4"), sender: Sender(id: helper.rawValue, timeZone: utc),
        senderSession: helper, content: .init(text: "a4"),
      )
      try await runtime.drain()
    }
    #expect(await messages.values.map(\.badge) == [2, 2, 2, 1])
  }

  // Only an unarchived box can show a sidebar dot, so only one counts.
  @Test func theBadgeLeavesOutArchivedBoxesAndDirectMessages() async throws {
    let messages = MessageCollector()
    let (space, owner) = try await relaySpace(grants: ["g1_live"])
    let persona = try #require(await onlyPersona(space))
    let helperRow = try await space.query("SELECT id FROM sessions WHERE title = 'helper'", as: .shared(.anonymous)).rows
    guard case let .text(helperID)? = helperRow.first?.first else { Issue.record("no helper"); return }
    let helper = SessionID(helperID)
    let utc = TimeZone(identifier: "UTC")!
    let runtime = PushRelayRuntime(
      space: space,
      logger: Logger(label: "push-relay-test"),
      client: PushRelayClient { await messages.append($0) },
    )

    try await withDependencies {
      $0.date = .constant(fixedDate)
    } operation: {
      try await runtime.drain()
      for id in ["d1", "d2"] {
        if id == "d2" { try await space.sessions.archive(owner, grace: .seconds(3600)) }
        _ = try await space.sessions.post(
          .dm(with: persona), messageID: MessageID(id), sender: Sender(id: helper.rawValue, timeZone: utc),
          senderSession: helper, content: .init(text: id),
        )
        try await runtime.drain()
      }
    }
    #expect(await messages.values.map(\.badge) == [1, 1, 0])
  }

  @Test func concurrentDrainsNeverDuplicateADelivery() async throws {
    let messages = MessageCollector()
    let entered = Gate()
    let release = Gate()
    let (space, _) = try await relaySpace(grants: ["g1_live"])

    try await withDependencies {
      $0.date = .constant(fixedDate)
    } operation: {
      let runtime = PushRelayRuntime(
        space: space,
        logger: Logger(label: "push-relay-test"),
        client: PushRelayClient { message in
          entered.open()
          await release.wait()
          await messages.append(message)
        },
      )
      let first = Task { try await runtime.drain() }
      await entered.wait()
      try await runtime.drain()
      release.open()
      try await first.value
    }

    #expect(await messages.values.count == 1)
  }
}

private actor MessageCollector {
  private(set) var values: [PushRelayMessage] = []
  func append(_ message: PushRelayMessage) { values.append(message) }
}

private func onlyPersona(_ space: Space) async -> String? {
  try? await space.personas().only?.name
}

private func relaySpace(grants: [String]) async throws -> (space: Space, owner: SessionID) {
  try await withDependencies {
    $0.date = .constant(fixedDate)
  } operation: {
    let space = try Space.inMemory()
    let account = try await space.addAccount(kind: .human, name: nil)
    let key = try await space.addKey(
      testPubkey("relay-device"),
      account: account.id,
      capabilities: [.device],
      createdBy: nil,
      expiresAt: nil,
    )
    let persona = try await space.adoptPersona(key: key)
    let model = ModelSpecifier(provider: "testing", model: "test-model", effort: "medium")
    let owner = try await space.sessions.createSession(
      group: .shared,
      title: "owner", kind: .agent, createdBy: persona.name, model: model,
    )
    let helper = try await space.sessions.createSession(
      group: .shared,
      title: "helper", kind: .agent, createdBy: persona.name, model: model,
    )
    _ = try await space.sessions.post(
      .box(owner),
      messageID: MessageID("question"),
      sender: Sender(id: persona.name, timeZone: TimeZone(identifier: "UTC")!),
      content: .init(text: "question"),
    )
    for grant in grants {
      try await space.registerPushRelayGrant(PushRelayGrant(
        grant: grant,
        endpoint: "https://notifications.wuhu.ai/v1/push",
        token: grant + "_secret",
        recipient: persona.name,
        devicePublicKey: key.pubkey,
      ))
    }
    _ = try await space.sessions.post(
      .box(owner),
      messageID: MessageID("reply"),
      sender: Sender(id: helper.rawValue, timeZone: TimeZone(identifier: "UTC")!),
      senderSession: helper,
      replyTarget: MessageID("question"),
      content: .init(text: "answer"),
    )
    return (space, owner)
  }
}

private extension Collection {
  var only: Element? { count == 1 ? first : nil }
}
