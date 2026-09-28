import AsyncHTTPClient
import Dependencies
import Foundation
import Logging
import NIOCore
import Scratch
import SessionDomain
import SpaceCore
@testable import SpaceServer
import Testing
import WebPush

@Suite struct WebPushRuntimeTests {
  @Test func concurrentDrainsNeverDuplicateADelivery() async throws {
    let messages = MessageCollector()
    let entered = Gate()
    let release = Gate()
    let (space, _) = try await notificationSpace(endpoints: ["https://push.example/live"])

    try await withDependencies {
      $0.date = .constant(fixedDate)
    } operation: {
      let runtime = WebPushRuntime(
        space: space,
        logger: Logger(label: "web-push-test"),
        client: WebPushClient { message in
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

  @Test func deliveredMessageNavigatesToItsConversationAndDeadEndpointsDisappear() async throws {
    let messages = MessageCollector()
    let (space, owner) = try await notificationSpace(endpoints: [
      "https://push.example/dead",
      "https://push.example/live",
    ])

    try await withDependencies {
      $0.date = .constant(fixedDate)
    } operation: {
      try await WebPushRuntime(
        space: space,
        logger: Logger(label: "web-push-test"),
        client: WebPushClient { message in
          if message.endpoint.hasSuffix("/dead") {
            throw WebPushTransportError(status: 410, retryAfter: nil, underlying: "gone")
          }
          await messages.append(message)
        },
      ).drain()
    }

    let message = try #require(await messages.values.only)
    #expect(message.title == "helper · owner")
    #expect(message.body == "answer")
    #expect(message.destination.path.hasPrefix("/_/conversations/"))
    #expect(try await space.dueWebPushDeliveries(at: fixedDate).isEmpty)
    _ = try await space.sessions.post(
      .box(owner),
      messageID: MessageID("reply-2"),
      sender: Sender(id: "other", timeZone: TimeZone(identifier: "UTC")!),
      replyTarget: MessageID("question"),
      content: .init(text: "second answer"),
    )
    #expect(try await space.dueWebPushDeliveries(at: fixedDate).map(\.endpoint) == ["https://push.example/live"])
  }

  @Test func aMessageNamesWhoSpokeAndTheBoxItWasPostedIn() async throws {
    let messages = MessageCollector()
    let (space, owner) = try await notificationSpace(endpoints: ["https://push.example/live"])

    try await withDependencies {
      $0.date = .constant(fixedDate)
    } operation: {
      let account = try await space.addAccount(kind: .human, name: nil)
      let colleague = try await space.adoptPersona(key: try await space.addKey(
        testPubkey("colleague"),
        account: account.id,
        capabilities: [.device],
        createdBy: nil,
        expiresAt: nil,
      ))
      _ = try await space.setUserProfile(principal: colleague.name, handle: "colleague", displayName: "Ada")
      for (sender, session) in [(owner.rawValue, owner), (colleague.name, nil)] {
        _ = try await space.sessions.post(
          .box(owner),
          messageID: MessageID("from-\(sender)"),
          sender: Sender(id: sender, timeZone: TimeZone(identifier: "UTC")!),
          senderSession: session,
          content: .init(text: "hello"),
        )
      }
      try await WebPushRuntime(
        space: space,
        logger: Logger(label: "web-push-test"),
        client: WebPushClient { await messages.append($0) },
      ).drain()
    }

    #expect(await messages.values.map(\.title) == ["helper · owner", "owner", "Ada · owner"])
  }

  // One inbox spans every group: a push names the notification's group, and a
  // sender from outside the conversation's group shows with theirs.
  @Test func anOutsideSenderIsTitledWithTheirGroup() async throws {
    let messages = MessageCollector()
    let (space, owner) = try await notificationSpace(endpoints: ["https://push.example/live"])
    let alice = try await withDependencies {
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
      try await WebPushRuntime(
        space: space,
        logger: Logger(label: "web-push-test"),
        client: WebPushClient { await messages.append($0) },
      ).drain()
      return alice
    }
    #expect(await messages.values.map(\.title) == ["helper · owner", "visitor (group \(alice.rawValue)) · owner"])
    #expect(await messages.values.map(\.group) == ["shared", "shared"])
  }

  @Test func aSessionEventIsTitledWithTheSessionItIsAbout() async throws {
    let (space, owner) = try await notificationSpace(endpoints: [])
    try await withDependencies {
      $0.date = .constant(fixedDate)
    } operation: {
      let worker = try await space.sessions.createSession(
        group: .shared,
        title: "worker",
        kind: .task,
        createdBy: "owner",
        model: ModelSpecifier(provider: "testing", model: "test-model", effort: "medium"),
      )
      try await space.sessions.recordRequestDeadline(
        parent: owner,
        task: worker,
        request: RequestID("request"),
        deadline: fixedDate,
      )
    }
    let deadline = try #require(try await space.sessions.notifications(recipient: "owner").only)
    #expect(try await NotificationOrigin(deadline, space: space) == .session("worker"))
  }

  @Test func transientFailureDefersTheSameNotification() async throws {
    let (space, _) = try await notificationSpace(endpoints: ["https://push.example/retry"])
    try await withDependencies {
      $0.date = .constant(fixedDate)
    } operation: {
      try await WebPushRuntime(
        space: space,
        logger: Logger(label: "web-push-test"),
        client: WebPushClient { _ in
          throw WebPushTransportError(status: 503, retryAfter: "30", underlying: "busy")
        },
      ).drain()
    }

    #expect(try await space.dueWebPushDeliveries(at: fixedDate.addingTimeInterval(29)).isEmpty)
    let retried = try #require(try await space.dueWebPushDeliveries(at: fixedDate.addingTimeInterval(30)).only)
    #expect(retried.consecutiveFailures == 1)
    #expect(retried.notification.kind == .conversationMessage)
  }

  @Test func pushServiceRejectionCarriesTheServiceBody() async throws {
    let response = HTTPClientResponse(
      status: .forbidden,
      headers: ["retry-after": "60"],
      body: .bytes(ByteBuffer(string: #"{"reason":"BadJwtToken"}"#)),
    )
    let error = await WebPushTransportError(PushServiceError(response: response))
    #expect(error.status == 403)
    #expect(error.retryAfter == "60")
    #expect(error.underlying.contains("BadJwtToken"))
  }

  @Test func vapidKeyIsStableAndStoredAsASecret() async throws {
    let directory = try scratchURL("wuhu-web-push")
    defer { try? FileManager.default.removeItem(at: directory) }
    let contact = URL(string: "https://space.example")!

    let first = try await WebPushKeyStore.loadOrCreate(directory: directory, contact: contact)
    let second = try await WebPushKeyStore.loadOrCreate(directory: directory, contact: contact)
    #expect(first.primaryKey == second.primaryKey)
    let file = directory.appendingPathComponent("vapid.json")
    let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
    #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
  }
}

private actor MessageCollector {
  private(set) var values: [WebPushMessage] = []
  func append(_ message: WebPushMessage) { values.append(message) }
}

private func notificationSpace(endpoints: [String]) async throws -> (space: Space, owner: SessionID) {
  try await withDependencies {
    $0.date = .constant(fixedDate)
  } operation: {
    let space = try Space.inMemory()
    let account = try await space.addAccount(kind: .human, name: nil)
    let key = try await space.addKey(
      testPubkey("push-device"),
      account: account.id,
      capabilities: [.device],
      createdBy: nil,
      expiresAt: nil,
    )
    let persona = try await space.adoptPersona(key: key)
    let model = ModelSpecifier(provider: "testing", model: "test-model", effort: "medium")
    let owner = try await space.sessions.createSession(group: .shared, title: "owner", kind: .agent, createdBy: persona.name, model: model)
    let helper = try await space.sessions.createSession(group: .shared, title: "helper", kind: .agent, createdBy: persona.name, model: model)
    _ = try await space.sessions.post(
      .box(owner),
      messageID: MessageID("question"),
      sender: Sender(id: persona.name, timeZone: TimeZone(identifier: "UTC")!),
      content: .init(text: "question"),
    )
    for endpoint in endpoints {
      try await space.registerWebPushSubscription(.init(
        endpoint: endpoint,
        recipient: persona.name,
        devicePublicKey: key.pubkey,
        p256dh: "p256dh",
        auth: "auth",
        vapidKeyID: "vapid",
        expiresAt: nil,
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
