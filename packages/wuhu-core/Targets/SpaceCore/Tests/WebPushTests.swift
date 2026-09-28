import Foundation
import SessionDomain
@testable import SpaceCore
import Testing

@Suite struct WebPushTests {
  @Test func subscriptionStartsAtNowAndAdvancesOneNotificationAtATime() async throws {
    let space = try makeSpace()
    let account = try await space.addAccount(kind: .human, name: nil)
    let key = try await space.addKey(
      testPubkey("phone"),
      account: account.id,
      capabilities: [.device],
      createdBy: nil,
      expiresAt: nil,
    )
    let persona = try await space.adoptPersona(key: key)
    let owner = try await space.sessions.createSession(group: .shared, title: "owner", kind: .agent, createdBy: persona.name, model: .test)
    let helper = try await space.sessions.createSession(group: .shared, title: "helper", kind: .agent, createdBy: persona.name, model: .test)
    let sender = Sender(id: persona.name, timeZone: TimeZone(identifier: "UTC")!)
    let helperSender = Sender(id: helper.rawValue, timeZone: TimeZone(identifier: "UTC")!)

    _ = try await space.sessions.post(
      .box(owner),
      messageID: MessageID("question"),
      sender: sender,
      content: .init(text: "question"),
    )
    _ = try await space.sessions.post(
      .box(owner),
      messageID: MessageID("historical"),
      sender: helperSender,
      senderSession: helper,
      replyTarget: MessageID("question"),
      content: .init(text: "before enrollment"),
    )

    let registration = WebPushSubscriptionRegistration(
      endpoint: "https://push.example/subscription",
      recipient: persona.name,
      devicePublicKey: key.pubkey,
      p256dh: "p256dh",
      auth: "auth",
      vapidKeyID: "vapid",
      expiresAt: nil,
    )
    try await space.registerWebPushSubscription(registration)
    #expect(try await space.dueWebPushDeliveries(at: fixedDate).isEmpty)

    _ = try await space.sessions.post(
      .box(owner),
      messageID: MessageID("first"),
      sender: helperSender,
      senderSession: helper,
      replyTarget: MessageID("question"),
      content: .init(text: "first live reply"),
    )
    _ = try await space.sessions.post(
      .box(owner),
      messageID: MessageID("second"),
      sender: helperSender,
      senderSession: helper,
      replyTarget: MessageID("question"),
      content: .init(text: "second live reply"),
    )

    let first = try #require(try await space.dueWebPushDeliveries(at: fixedDate).only)
    #expect(first.notification.payload.contains("first live reply"))
    try await space.markWebPushDelivered(endpoint: first.endpoint, notification: first.notification.n)
    let second = try #require(try await space.dueWebPushDeliveries(at: fixedDate).only)
    #expect(second.notification.payload.contains("second live reply"))
    try await space.markWebPushDelivered(endpoint: second.endpoint, notification: second.notification.n)
    #expect(try await space.dueWebPushDeliveries(at: fixedDate).isEmpty)

    try await space.registerWebPushSubscription(registration)
    #expect(try await space.dueWebPushDeliveries(at: fixedDate).isEmpty)
  }

  @Test func retryExpiryAndCredentialRevocationOwnTheSubscriptionLifecycle() async throws {
    let space = try makeSpace()
    let account = try await space.addAccount(kind: .human, name: nil)
    let key = try await space.addKey(
      testPubkey("tablet"),
      account: account.id,
      capabilities: [.device],
      createdBy: nil,
      expiresAt: nil,
    )
    let persona = try await space.adoptPersona(key: key)
    let owner = try await space.sessions.createSession(group: .shared, title: "owner", kind: .agent, createdBy: persona.name, model: .test)
    let helper = try await space.sessions.createSession(group: .shared, title: "helper", kind: .agent, createdBy: persona.name, model: .test)
    let sender = Sender(id: persona.name, timeZone: TimeZone(identifier: "UTC")!)
    let helperSender = Sender(id: helper.rawValue, timeZone: TimeZone(identifier: "UTC")!)

    _ = try await space.sessions.post(
      .box(owner),
      messageID: MessageID("question"),
      sender: sender,
      content: .init(text: "question"),
    )
    try await space.registerWebPushSubscription(.init(
      endpoint: "https://push.example/live",
      recipient: persona.name,
      devicePublicKey: key.pubkey,
      p256dh: "p256dh",
      auth: "auth",
      vapidKeyID: "vapid",
      expiresAt: nil,
    ))
    try await space.registerWebPushSubscription(.init(
      endpoint: "https://push.example/expired",
      recipient: persona.name,
      devicePublicKey: key.pubkey,
      p256dh: "p256dh",
      auth: "auth",
      vapidKeyID: "vapid",
      expiresAt: fixedDate.addingTimeInterval(1),
    ))
    _ = try await space.sessions.post(
      .box(owner),
      messageID: MessageID("reply"),
      sender: helperSender,
      senderSession: helper,
      replyTarget: MessageID("question"),
      content: .init(text: "reply"),
    )

    let deliveries = try await space.dueWebPushDeliveries(at: fixedDate)
    #expect(deliveries.map(\.endpoint) == ["https://push.example/expired", "https://push.example/live"])
    try await space.deferWebPushDelivery(endpoint: "https://push.example/live", until: fixedDate.addingTimeInterval(30))
    #expect(try await space.dueWebPushDeliveries(at: fixedDate).map(\.endpoint) == ["https://push.example/expired"])
    #expect(try await space.dueWebPushDeliveries(at: fixedDate.addingTimeInterval(2)).isEmpty)

    try await space.removeKey(pubkey: key.pubkey)
    #expect(try await space.dueWebPushDeliveries(at: fixedDate.addingTimeInterval(31)).isEmpty)
  }
}

private extension Collection {
  var only: Element? { count == 1 ? first : nil }
}
