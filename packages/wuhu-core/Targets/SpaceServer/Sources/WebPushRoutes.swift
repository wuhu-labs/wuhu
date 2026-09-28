import Dependencies
import Fetch
import Foundation
import Serve
import ServeRouting
import SpaceContract
import SpaceCore
import WebPush

func addWebPushRoutes(
  _ router: inout Router,
  space: Space,
  applicationServerKey: String,
) {
  @Dependency(\.date) var date

  router.get("/v1/web-push/config") { request, _ in
    switch try await personaCredentialVerdict(nil, request: request, space: space, now: date.now) {
    case .anonymous:
      return errorResponse(.unauthorized, code: "unauthorized", message: "a bearer assertion is required")
    case let .refused(response):
      return response
    case .verified:
      return try Response.json(WebPushConfigOutput(applicationServerKey: applicationServerKey))
    }
  }

  router.put("/v1/web-push/subscription") { request, _ in
    let input: WebPushSubscriptionInput
    do {
      input = try await request.json(WebPushSubscriptionInput.self)
    } catch {
      return errorResponse(.badRequest, code: "invalidArgument", message: "expected a web-push subscription body: \(error)")
    }
    guard input.applicationServerKey == applicationServerKey,
          let endpoint = URL(string: input.endpoint), endpoint.scheme == "https", endpoint.host != nil,
          input.endpoint.utf8.count <= 4096,
          (try? UserAgentKeyMaterial(publicKey: input.p256dh, authenticationSecret: input.auth)) != nil
    else {
      return errorResponse(.badRequest, code: "invalidArgument", message: "invalid web-push subscription")
    }
    let expiresAt: Date?
    if let expirationTime = input.expirationTime {
      guard expirationTime.isFinite else {
        return errorResponse(.badRequest, code: "invalidArgument", message: "invalid subscription expiration")
      }
      let value = Date(timeIntervalSince1970: expirationTime / 1000)
      guard value > date.now else {
        return errorResponse(.badRequest, code: "invalidArgument", message: "subscription is already expired")
      }
      expiresAt = value
    } else {
      expiresAt = nil
    }
    switch try await personaCredentialVerdict(nil, request: request, space: space, now: date.now) {
    case .anonymous:
      return errorResponse(.unauthorized, code: "unauthorized", message: "a bearer assertion is required")
    case let .refused(response):
      return response
    case let .verified(persona, key):
      try await space.registerWebPushSubscription(WebPushSubscriptionRegistration(
        endpoint: input.endpoint,
        recipient: persona.name,
        devicePublicKey: key.pubkey,
        p256dh: input.p256dh,
        auth: input.auth,
        vapidKeyID: input.applicationServerKey,
        expiresAt: expiresAt,
      ))
      return Response(status: .noContent)
    }
  }

  router.delete("/v1/web-push/subscription") { request, _ in
    let input: WebPushSubscriptionDeleteInput
    do {
      input = try await request.json(WebPushSubscriptionDeleteInput.self)
    } catch {
      return errorResponse(.badRequest, code: "invalidArgument", message: "expected a web-push deletion body: \(error)")
    }
    switch try await personaCredentialVerdict(nil, request: request, space: space, now: date.now) {
    case .anonymous:
      return errorResponse(.unauthorized, code: "unauthorized", message: "a bearer assertion is required")
    case let .refused(response):
      return response
    case let .verified(_, key):
      try await space.removeWebPushSubscription(endpoint: input.endpoint, devicePublicKey: key.pubkey)
      return Response(status: .noContent)
    }
  }
}
