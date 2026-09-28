import Assertion
import Crypto
import Fetch
import Foundation
import HTTPTypes
import JSONValue
import SessionDomain
import SpaceContract
import SpaceCore
import Testing

@Suite struct WebPushRouteTests {
  let applicationServerKey = "vapid-public-key"
  let key = Curve25519.Signing.PrivateKey()
  let harness: Harness
  let identity: String
  let account: AccountID

  init() async throws {
    harness = try Harness(dev: false, webPushApplicationServerKey: applicationServerKey)
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

  @Test func configAndSubscriptionLifecycleRequireTheEnrolledDevice() async throws {
    #expect(try await harness.get(harness.api, "/v1/web-push/config").status == .unauthorized)

    let config = try await request("/v1/web-push/config")
    #expect(config.status == .ok)
    let output = try JSONValueDecoder().decode(WebPushConfigOutput.self, from: try await json(config))
    #expect(output.applicationServerKey == applicationServerKey)

    let input = WebPushSubscriptionInput(
      endpoint: "https://push.example/subscription",
      p256dh: "BMXVxJELqTqIqMka5N8ujvW6RXI9zo_xr5BQ6XGDkrsukNVPyKRMEEfzvQGeUdeZaWAaAs2pzyv1aoHEXYMtj1M",
      auth: "IzODAQZN6BbGvmm7vWQJXg",
      applicationServerKey: applicationServerKey,
      expirationTime: nil,
    )
    #expect(try await request("/v1/web-push/subscription", method: .put, body: input).status == .noContent)
    #expect(try await request("/v1/web-push/subscription", method: .put, body: input).status == .noContent)
    try await notifyPersona()
    #expect(try await harness.space.dueWebPushDeliveries(at: fixedDate).count == 1)

    #expect(try await request(
      "/v1/web-push/subscription",
      method: .delete,
      body: WebPushSubscriptionDeleteInput(endpoint: input.endpoint),
    ).status == .noContent)
    #expect(try await harness.space.dueWebPushDeliveries(at: fixedDate).isEmpty)
  }

  @Test func malformedOrMismatchedSubscriptionsAreRefused() async throws {
    let malformed = WebPushSubscriptionInput(
      endpoint: "http://push.example/subscription",
      p256dh: "invalid",
      auth: "invalid",
      applicationServerKey: "another-key",
      expirationTime: nil,
    )
    #expect(try await request("/v1/web-push/subscription", method: .put, body: malformed).status == .badRequest)
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

  private func request(_ path: String) async throws -> Response {
    var request = Request(url: URL(string: "http://space\(path)")!)
    request.headers[.authorization] = "Bearer " + (try assertion())
    return try await harness.api(request)
  }

  private func assertion() throws -> String {
    try AssertionClaims(
      key: key.pubkeyLabel,
      space: identity,
      expiresAt: fixedDate.addingTimeInterval(3600),
    ).signed(by: key).rawValue
  }

  private func notifyPersona() async throws {
    let persona = try #require(try await harness.space.persona(account: account))
    let model = ModelSpecifier(provider: "testing", model: "test-model", effort: "medium")
    let owner = try await harness.space.sessions.createSession(group: .shared, title: "owner", kind: .agent, createdBy: persona.name, model: model)
    _ = try await harness.space.sessions.post(
      .box(owner),
      messageID: MessageID("question"),
      sender: Sender(id: persona.name, timeZone: TimeZone(identifier: "UTC")!),
      content: .init(text: "question"),
    )
    _ = try await harness.space.sessions.post(
      .box(owner),
      messageID: MessageID("reply"),
      sender: Sender(id: "other", timeZone: TimeZone(identifier: "UTC")!),
      replyTarget: MessageID("question"),
      content: .init(text: "reply"),
    )
  }
}
