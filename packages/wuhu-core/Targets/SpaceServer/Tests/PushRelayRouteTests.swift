import Assertion
import Crypto
import Fetch
import Foundation
import HTTPTypes
import SessionDomain
import SpaceContract
import SpaceCore
@testable import SpaceServer
import Testing

@Suite struct PushRelayRouteTests {
  let key = Curve25519.Signing.PrivateKey()
  let harness: Harness
  let identity: String
  let account: AccountID

  init() async throws {
    harness = try Harness(dev: false)
    identity = try await harness.space.identity().rawValue
    let account = try await harness.space.addAccount(kind: .human, name: nil)
    self.account = account.id
    _ = try await harness.space.addKey(
      key.pubkeyLabel,
      account: account.id,
      capabilities: [.device],
      createdBy: nil,
      expiresAt: nil,
    )
  }

  @Test func grantLifecycleRequiresTheEnrolledDevice() async throws {
    var anonymous = Request(url: URL(string: "http://space/v1/push-relay/grant")!, method: .put)
    anonymous.body = try Body.json(grant)
    #expect(try await harness.api(anonymous).status == .unauthorized)

    #expect(try await request("/v1/push-relay/grant", method: .put, body: grant).status == .noContent)
    #expect(try await request("/v1/push-relay/grant", method: .put, body: grant).status == .noContent)
    try await notifyPersona()
    let due = try #require(try await harness.space.duePushRelayDeliveries(at: fixedDate).only)
    #expect(due.grant == grant.grant)
    #expect(due.token == grant.token)

    #expect(try await request(
      "/v1/push-relay/grant",
      method: .delete,
      body: PushRelayGrantDeleteInput(grant: grant.grant),
    ).status == .noContent)
    #expect(try await harness.space.duePushRelayDeliveries(at: fixedDate).isEmpty)
  }

  // The device republishes the same credential on every trigger, so this runs
  // constantly against a live row. It must neither skip a notification that has
  // not been accepted yet nor rewind and replay one that has.
  @Test func republishingTheSameCredentialLeavesTheCursorWhereItIs() async throws {
    #expect(try await request("/v1/push-relay/grant", method: .put, body: grant).status == .noContent)
    try await notifyPersona()
    let pending = try #require(try await harness.space.duePushRelayDeliveries(at: fixedDate).only)

    #expect(try await request("/v1/push-relay/grant", method: .put, body: grant).status == .noContent)
    let afterRepublish = try #require(try await harness.space.duePushRelayDeliveries(at: fixedDate).only)
    #expect(afterRepublish.notification.n == pending.notification.n)

    try await harness.space.markPushRelayAccepted(grant.grant, notification: pending.notification.n)
    #expect(try await harness.space.duePushRelayDeliveries(at: fixedDate).isEmpty)
    #expect(try await request("/v1/push-relay/grant", method: .put, body: grant).status == .noContent)
    #expect(try await harness.space.duePushRelayDeliveries(at: fixedDate).isEmpty)
  }

  // A 410 from the relay deletes the row. The device holds the same credential
  // and republishes it, which must restore delivery without replaying what the
  // space already handed over.
  @Test func aDroppedGrantIsRestoredByTheNextRepublish() async throws {
    #expect(try await request("/v1/push-relay/grant", method: .put, body: grant).status == .noContent)
    try await notifyPersona()
    let first = try #require(try await harness.space.duePushRelayDeliveries(at: fixedDate).only)
    try await harness.space.markPushRelayAccepted(grant.grant, notification: first.notification.n)

    try await harness.space.removePushRelayGrant(grant.grant)
    #expect(try await harness.space.pushRelayGrants(recipient: try #require(await persona())).isEmpty)

    #expect(try await request("/v1/push-relay/grant", method: .put, body: grant).status == .noContent)
    #expect(try await harness.space.duePushRelayDeliveries(at: fixedDate).isEmpty)

    try await notifyPersona(thread: "second")
    let resumed = try #require(try await harness.space.duePushRelayDeliveries(at: fixedDate).only)
    #expect(resumed.notification.n > first.notification.n)
  }

  // A grant backing off after a transient refusal is re-enabled by the next
  // republish rather than waiting out its retry window.
  @Test func republishingClearsTheBackoff() async throws {
    #expect(try await request("/v1/push-relay/grant", method: .put, body: grant).status == .noContent)
    try await notifyPersona()
    let pending = try #require(try await harness.space.duePushRelayDeliveries(at: fixedDate).only)
    try await harness.space.deferPushRelayDelivery(grant.grant, until: fixedDate.addingTimeInterval(3600))
    #expect(try await harness.space.duePushRelayDeliveries(at: fixedDate).isEmpty)

    #expect(try await request("/v1/push-relay/grant", method: .put, body: grant).status == .noContent)
    let revived = try #require(try await harness.space.duePushRelayDeliveries(at: fixedDate).only)
    #expect(revived.notification.n == pending.notification.n)
    #expect(revived.consecutiveFailures == 0)
  }

  // A grant id is opaque but not secret: it travels in every push payload. A
  // second enrolled device must not be able to seize one by naming it, which
  // would repoint another device's notifications or simply destroy them.
  @Test func anotherDeviceCannotSeizeAGrantByNamingIt() async throws {
    #expect(try await request("/v1/push-relay/grant", method: .put, body: grant).status == .noContent)

    let intruder = Curve25519.Signing.PrivateKey()
    let other = try await harness.space.addAccount(kind: .human, name: nil)
    _ = try await harness.space.addKey(
      intruder.pubkeyLabel,
      account: other.id,
      capabilities: [.device],
      createdBy: nil,
      expiresAt: nil,
    )
    let seizure = PushRelayGrantInput(
      endpoint: "https://notifications.wuhu.ai/v1/push",
      grant: grant.grant,
      token: "g1_abc_secret_stolen",
    )
    var request = Request(url: URL(string: "http://space/v1/push-relay/grant")!, method: .put)
    request.headers[.authorization] = "Bearer " + (try assertion(intruder))
    request.body = try Body.json(seizure)
    #expect(try await harness.api(request).status == .conflict)

    try await notifyPersona()
    let due = try #require(try await harness.space.duePushRelayDeliveries(at: fixedDate).only)
    #expect(due.token == grant.token)
  }

  // A device names the endpoint the space will carry a bearer token to, so an
  // unlisted host must be refused rather than dialled.
  @Test func endpointsOutsideTheAllowlistAreRefused() async throws {
    for endpoint in [
      "https://attacker.example/v1/push",
      "http://notifications.wuhu.ai/v1/push",
      "https://notifications.wuhu.ai.attacker.example/v1/push",
    ] {
      let input = PushRelayGrantInput(
        endpoint: endpoint,
        grant: "g1_abc",
        token: "g1_abc_secret",
      )
      #expect(try await request("/v1/push-relay/grant", method: .put, body: input).status == .badRequest)
    }
    #expect(try await harness.space.pushRelayGrants(recipient: "").isEmpty)
  }

  @Test func theAllowlistDefaultsToTheGatewayAndIsOverridable() {
    #expect(pushRelayHosts([:]) == ["notifications.wuhu.ai"])
    #expect(pushRelayHosts(["WUHU_PUSH_RELAY_HOSTS": " Relay.Test , other.test "]) == ["relay.test", "other.test"])
    #expect(pushRelayHosts(["WUHU_PUSH_RELAY_HOSTS": "  "]) == ["notifications.wuhu.ai"])
  }

  private var grant: PushRelayGrantInput {
    PushRelayGrantInput(
      endpoint: "https://notifications.wuhu.ai/v1/push",
      grant: "g1_abc",
      token: "g1_abc_secret",
    )
  }

  private func request<Input: Encodable>(
    _ path: String,
    method: HTTPRequest.Method,
    body: Input,
  ) async throws -> Response {
    var request = Request(url: URL(string: "http://space\(path)")!, method: method)
    request.headers[.authorization] = "Bearer " + (try assertion())
    request.body = try Body.json(body)
    return try await harness.api(request)
  }

  private func assertion(_ signer: Curve25519.Signing.PrivateKey? = nil) throws -> String {
    let signer = signer ?? key
    return try AssertionClaims(
      key: signer.pubkeyLabel,
      space: identity,
      expiresAt: fixedDate.addingTimeInterval(3600),
    ).signed(by: signer).rawValue
  }

  private func persona() async -> String? {
    try? await harness.space.persona(account: account)?.name
  }

  private func notifyPersona(thread: String = "first") async throws {
    let persona = try #require(try await harness.space.persona(account: account))
    let model = ModelSpecifier(provider: "testing", model: "test-model", effort: "medium")
    let owner = try await harness.space.sessions.createSession(
      group: .shared,
      title: "owner \(thread)", kind: .agent, createdBy: persona.name, model: model,
    )
    _ = try await harness.space.sessions.post(
      .box(owner),
      messageID: MessageID("question-\(thread)"),
      sender: Sender(id: persona.name, timeZone: TimeZone(identifier: "UTC")!),
      content: .init(text: "question"),
    )
    _ = try await harness.space.sessions.post(
      .box(owner),
      messageID: MessageID("reply-\(thread)"),
      sender: Sender(id: "other", timeZone: TimeZone(identifier: "UTC")!),
      replyTarget: MessageID("question-\(thread)"),
      content: .init(text: "reply"),
    )
  }
}

private extension Collection {
  var only: Element? { count == 1 ? first : nil }
}
