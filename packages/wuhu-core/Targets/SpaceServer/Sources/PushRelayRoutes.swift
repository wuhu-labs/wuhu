import Dependencies
import Fetch
import Foundation
import Serve
import ServeRouting
import SpaceContract
import SpaceCore

let defaultPushRelayHosts: Set<String> = ["notifications.wuhu.ai"]

func pushRelayHosts(_ environment: [String: String]) -> Set<String> {
  guard let raw = environment["WUHU_PUSH_RELAY_HOSTS"] else { return defaultPushRelayHosts }
  let hosts = raw.split(separator: ",")
    .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
    .filter { !$0.isEmpty }
  return hosts.isEmpty ? defaultPushRelayHosts : Set(hosts)
}

func addPushRelayRoutes(
  _ router: inout Router,
  space: Space,
  allowedHosts: Set<String>,
) {
  @Dependency(\.date) var date

  router.put("/v1/push-relay/grant") { request, _ in
    let input: PushRelayGrantInput
    do {
      input = try await request.json(PushRelayGrantInput.self)
    } catch {
      return errorResponse(.badRequest, code: "invalidArgument", message: "expected a push-relay grant body: \(error)")
    }
    // An enrolled device chooses the endpoint, so the server must not be
    // willing to POST a bearer token at an arbitrary host on its say-so.
    guard let endpoint = URL(string: input.endpoint), endpoint.scheme == "https",
          let host = endpoint.host, allowedHosts.contains(host.lowercased()),
          input.endpoint.utf8.count <= 4096,
          !input.grant.isEmpty, input.grant.utf8.count <= 256,
          !input.token.isEmpty, input.token.utf8.count <= 4096
    else {
      return errorResponse(.badRequest, code: "invalidArgument", message: "invalid push-relay grant")
    }
    switch try await personaCredentialVerdict(nil, request: request, space: space, now: date.now) {
    case .anonymous:
      return errorResponse(.unauthorized, code: "unauthorized", message: "a bearer assertion is required")
    case let .refused(response):
      return response
    case let .verified(persona, key):
      do {
        try await space.registerPushRelayGrant(PushRelayGrant(
          grant: input.grant,
          endpoint: input.endpoint,
          token: input.token,
          recipient: persona.name,
          devicePublicKey: key.pubkey,
        ))
      } catch is PushRelayGrantOwnedElsewhere {
        return errorResponse(.conflict, code: "conflict", message: "that grant belongs to another device")
      }
      return Response(status: .noContent)
    }
  }

  router.delete("/v1/push-relay/grant") { request, _ in
    let input: PushRelayGrantDeleteInput
    do {
      input = try await request.json(PushRelayGrantDeleteInput.self)
    } catch {
      return errorResponse(.badRequest, code: "invalidArgument", message: "expected a push-relay deletion body: \(error)")
    }
    switch try await personaCredentialVerdict(nil, request: request, space: space, now: date.now) {
    case .anonymous:
      return errorResponse(.unauthorized, code: "unauthorized", message: "a bearer assertion is required")
    case let .refused(response):
      return response
    case let .verified(_, key):
      try await space.removePushRelayGrant(input.grant, devicePublicKey: key.pubkey)
      return Response(status: .noContent)
    }
  }
}
