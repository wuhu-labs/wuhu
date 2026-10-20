import Dependencies
import Fetch
#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import HTTPTypes
import SpaceClient

/// The transport an identity fetch's hops go out on: one that answers a
/// redirect instead of following it, so the token is re-sent to its own
/// origin only. The process binds the real one; the default refuses.
public enum ScriptHopKey: TestDependencyKey, DependencyKey {
  public static var liveValue: FetchClient { FetchClient { _ in throw FetchError.unimplemented } }
  public static var testValue: FetchClient { liveValue }
}

extension DependencyValues {
  public var scriptHop: FetchClient {
    get { self[ScriptHopKey.self] }
    set { self[ScriptHopKey.self] = newValue }
  }
}

/// What the script's `fetch` answers as `{error: {code, message}}` instead of a
/// response: the token could not be minted.
struct ScriptIdentityFailure: Error {
  let code: String
  let message: String
}

private enum ScriptHopError: Error {
  case invalidRedirect
}

private let identityHops = 20
private let identityWindow: Duration = .seconds(60)

/// `fetch(url, {identity: true})`: a token for the request's origin from main
/// (`GET /v1/id-token`), sent as the bearer on every hop to that origin and on
/// none other; up to 20 redirects within 60 s, a 303 (and a 301/302 of a POST)
/// turning the method into a bodiless GET. `protect` gets the token before
/// any hop, so it is masked wherever it shows up.
func identityResponse(_ request: Request, client: SpaceClient, protect: (String) -> Void) async throws -> Response {
  @Dependency(\.scriptHop) var scriptHop
  @Dependency(\.continuousClock) var clock
  let hop = scriptHop
  guard let origin = fetchOrigin(request.url) else {
    throw ScriptIdentityFailure(code: "invalidArgument", message: "identity needs an http(s) URL with a plain host: \(request.url)")
  }
  struct Minted: Decodable { let token: String }
  let token: String
  do {
    token = try await (client.api(.get, queryPath("/v1/id-token", [("audience", origin)])) as Minted).token
  } catch let failure as SpaceClient.ToolFailure {
    throw ScriptIdentityFailure(code: failure.error.code.rawValue, message: failure.error.message)
  } catch let failure as SpaceClient.TransportFailure {
    throw ScriptIdentityFailure(code: failure.code ?? "identityUnavailable", message: failure.message)
  }
  protect(token)
  let remaining = identityRemaining(clock)
  let timeout = FetchError.transportFailure(kind: .deadlineExceeded)
  var body = try await request.body?.bytes()
  var target = request
  for count in 0 ... identityHops {
    guard remaining() > .zero else { throw timeout }
    target.body = body.map { .bytes($0) }
    target.headers[.authorization] = fetchOrigin(target.url) == origin ? "Bearer " + token : nil
    let outgoing = target
    let response = try await withThrowingTaskGroup(of: Response.self) { tasks in
      tasks.addTask { try await hop(outgoing) }
      tasks.addTask { [clock] in
        try await clock.sleep(for: remaining())
        throw timeout
      }
      defer { tasks.cancelAll() }
      return try await tasks.next()!
    }
    guard [301, 302, 303, 307, 308].contains(response.status.code), let location = response.headers[.location] else {
      return bounded(response, remaining: remaining, clock: clock)
    }
    guard count < identityHops, let url = URL(string: location, relativeTo: target.url)?.absoluteURL, fetchOrigin(url) != nil else {
      throw ScriptHopError.invalidRedirect
    }
    target.url = url
    if (response.status.code == 303 && target.method != .head) || ([301, 302].contains(response.status.code) && target.method == .post) {
      target.method = .get
      body = nil
      target.headers[.contentType] = nil
      target.headers[.contentLength] = nil
    }
  }
  preconditionFailure()
}

/// `response` with its body under the window its head came in: a chunk that
/// hasn't arrived when `remaining()` runs out ends the read with the same
/// deadline failure, instead of a stalled upstream holding the script.
private func bounded<C: Clock>(_ response: Response, remaining: @escaping @Sendable () -> Duration, clock: C) -> Response where C.Duration == Duration {
  var response = response
  let base = response.body
  response.body = .stream(length: base.contentLength, contentType: base.contentType, AsyncThrowingStream<Bytes, any Error> { continuation in
    let reader = Task {
      do {
        for try await chunk in base.asyncBytes() { continuation.yield(chunk) }
        continuation.finish()
      } catch {
        continuation.finish(throwing: error)
      }
    }
    let watchdog = Task {
      let left = remaining()
      if left > .zero { try await clock.sleep(for: left) }
      continuation.finish(throwing: FetchError.transportFailure(kind: .deadlineExceeded))
      reader.cancel()
    }
    continuation.onTermination = { _ in
      reader.cancel()
      watchdog.cancel()
    }
  })
  return response
}

private func identityRemaining<C: Clock>(_ clock: C) -> @Sendable () -> Duration where C.Duration == Duration {
  let expires = clock.now.advanced(by: identityWindow)
  return { clock.now.duration(to: expires) }
}
