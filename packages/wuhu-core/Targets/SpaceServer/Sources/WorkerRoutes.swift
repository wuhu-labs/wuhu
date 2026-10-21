#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import Fetch
import Logging
import MainHub
import Serve
import ServeRouting
import ServeSSE
import SessionDomain
import SpaceCore

/// Every worker route answers in this envelope, so an absent value (`null`)
/// and a present one decode the same way on the worker. Dates cross as the
/// store writes them (`JSONEncoder`'s default), so what the worker holds is
/// equal to what main holds, bit for bit.
struct WorkerReply<Value: Codable>: Codable {
  var value: Value?
}

struct CompactClaimInput: Codable {
  var generation: Int
}

struct WakeAtInput: Codable {
  /// Seconds since 1970; nil clears the wake.
  var at: Double?
}

struct CacheWarmingInput: Codable {
  var intervalSeconds: Int
}

struct AudienceInput: Codable {
  var audience: String
}

// An OIDC audience is an absolute https or http URL.
private func audience(_ request: Request) async throws -> URL? {
  let input = try await request.json(AudienceInput.self, dateDecodingStrategy: .deferredToDate)
  guard input.audience.utf8.count <= 2048, let url = URL(string: input.audience), ["https", "http"].contains(url.scheme), url.host != nil else { return nil }
  return url
}

private struct OIDCUnavailable: Error, CustomStringConvertible {
  var description: String { "this server signs no OIDC tokens" }
}

private func invalid(_ message: String) -> Response { errorResponse(.badRequest, code: "invalidArgument", message: message) }

/// The loop's journal and queue as routes: what `Main` gives the loop in
/// process, for the worker's own token and nothing else. The gate sends only
/// the worker here; a session's or an exec's token never reaches these.
private func answer<Value: Codable>(_ body: () async throws -> Value?) async -> Response {
  do { return try Response.json(WorkerReply(value: try await body()), dateEncodingStrategy: .deferredToDate) } catch { return sessionErrorResponse(error) }
}

/// A session whose stored data no longer decodes is main's finding, named
/// to the worker as such: the verbs then say "Start over" instead of a
/// decoding error nobody can act on.
private func readable<Value>(_ id: SessionID, _ body: (SessionID) async throws -> Value) async throws -> Value {
  do { return try await body(id) } catch where error is DecodingError || error is ExecutorSpecError || (error as? CocoaError)?.code == .formatting {
    throw SessionError.unreadableData(id)
  }
}

private func noSession() -> Response { errorResponse(.badRequest, code: "invalidArgument", message: "a worker route names its session") }

func workerRouter(owner: Hub, runtime: SessionRuntime) -> Router {
  var router = Router()
  let (workers, tokens) = (runtime.workers, runtime.tokens)

  // The worker's line: main asks the worker's calls on it, for as long as it
  // is open. Opening it announces the worker.
  router.webSocket(workerLinePath) { request, _ in
    guard let bearer = request.headers[.authorization]?.dropFirst("Bearer ".count), let id = tokens.worker(ofBearer: String(bearer)) else {
      return .response(errorResponse(.unauthorized, code: "unauthorized", message: "a worker's line takes its own token"))
    }
    let holding = (request.headers[workerHoldingHeader] ?? "").split(separator: ",").map { SessionID(String($0)) }
    return .webSocket { socket in
      let line = WorkerClient(transport: WebSocketTransport(socket)) { notice in
        switch notice {
        case let .attempt(session, event): runtime.attempts.publish(session: session, event)
        case let .usage(provider, plan, windows, at): runtime.usage.record(provider, plan: plan, windows: windows, at: Date(timeIntervalSince1970: at))
        }
      }
      workers.announce(id, endpoint: line, holding: holding)
      Logger(label: "wuhu.workers").notice("worker announced", metadata: ["worker": "\(id.rawValue)", "holding": "\(holding.count)"])
      await line.run()
    }
  }

  router.get("/v1/worker/session/:id/owed-execs") { _, parameters in
    guard let id = parameters["id"] else { return noSession() }
    return await answer { try await owner.owedExecs(SessionID(id)) }
  }
  // The session's pending arrivals, now and after every change, as SSE.
  router.get("/v1/worker/session/:id/arrivals") { _, parameters in
    guard let id = parameters["id"] else { return noSession() }
    let encoder = JSONEncoder()
    return .sse(forwarding: owner.pendingArrivals(SessionID(id))) { arrivals in
      (try? encoder.encode(arrivals)).map { .message(String(decoding: $0, as: UTF8.self)) }
    }
  }
  router.post("/v1/worker/session/:id/events") { request, parameters in
    guard let id = parameters["id"] else { return noSession() }
    let event = try await request.json(SessionEvent.self, dateDecodingStrategy: .deferredToDate)
    return await answer { try await owner.append(SessionID(id), event) }
  }
  router.get("/v1/worker/session/:id/route") { _, parameters in
    guard let id = parameters["id"] else { return noSession() }
    return await answer { try await owner.modelRoute(SessionID(id)) }
  }
  router.get("/v1/worker/session/:id/record") { _, parameters in
    guard let id = parameters["id"] else { return noSession() }
    return await answer { try await readable(SessionID(id)) { try await owner.record($0) } }
  }
  router.get("/v1/worker/session/:id/hydration") { _, parameters in
    guard let id = parameters["id"] else { return noSession() }
    return await answer { try await readable(SessionID(id)) { try await owner.hydrate($0) } }
  }
  router.get("/v1/worker/session/:id/queue-head") { _, parameters in
    guard let id = parameters["id"] else { return noSession() }
    return await answer { try await owner.queueHead(SessionID(id)) }
  }
  router.get("/v1/worker/session/:id/command") { _, parameters in
    guard let id = parameters["id"] else { return noSession() }
    return await answer { try await owner.pendingCommand(SessionID(id)) }
  }
  router.get("/v1/worker/session/:id/subscriptions") { _, parameters in
    guard let id = parameters["id"] else { return noSession() }
    return await answer { try await owner.registeredSubscriptions(SessionID(id)) }
  }
  router.post("/v1/worker/session/:id/drain") { _, parameters in
    guard let id = parameters["id"] else { return noSession() }
    return await answer { try await owner.drainQueue(SessionID(id)) }
  }
  // The token the worker's tools present as the session.
  router.get("/v1/worker/session/:id/token") { _, parameters in
    guard let id = parameters["id"] else { return noSession() }
    return await answer { tokens.sessionToken(SessionID(id)) }
  }
  // When the session's parked loop wants to be woken, if nothing else does.
  router.post("/v1/worker/session/:id/wake-at") { request, parameters in
    guard let id = parameters["id"] else { return noSession() }
    let input = try await request.json(WakeAtInput.self, dateDecodingStrategy: .deferredToDate)
    if let at = input.at, !at.isFinite { return invalid("wake-at takes a finite time") }
    return await answer { () -> Bool? in
      await runtime.service.scheduleWake(SessionID(id), at: input.at.map(Date.init(timeIntervalSince1970:)))
      return nil
    }
  }
  router.get("/v1/worker/session/:id/cache-warming") { _, parameters in
    guard let id = parameters["id"] else { return noSession() }
    return await answer { try await CacheWarmer(space: owner.space, usage: runtime.usage).allows(SessionID(id)) }
  }
  router.post("/v1/worker/session/:id/cache-warming") { request, parameters in
    guard let id = parameters["id"] else { return noSession() }
    let input = try await request.json(CacheWarmingInput.self, dateDecodingStrategy: .deferredToDate)
    guard (1 ... 30 * 24 * 3600).contains(input.intervalSeconds) else { return invalid("cache warming takes an interval of 1 s to 30 days") }
    return await answer { () -> Bool? in
      try await owner.space.sessions.scheduleCacheWarming(SessionID(id), intervalSeconds: input.intervalSeconds)
      return nil
    }
  }
  // Main signs the OIDC tokens a worker's inferences present.
  let signing = runtime.signing
  router.post("/v1/worker/session/:id/oidc-token") { request, parameters in
    guard let id = parameters["id"] else { return noSession() }
    guard let url = try await audience(request) else { return invalid("an OIDC audience is an absolute http(s) URL") }
    return await answer { () -> String? in
      guard let sign = signing.oidcToken else { throw OIDCUnavailable() }
      return try await sign(url, SessionID(id))
    }
  }
  router.post("/v1/worker/session/:id/oidc-binding") { request, parameters in
    guard let id = parameters["id"] else { return noSession() }
    guard let url = try await audience(request) else { return invalid("an OIDC audience is an absolute http(s) URL") }
    return await answer { () -> String? in
      guard let bind = signing.oidcBindingIdentity else { throw OIDCUnavailable() }
      return try await bind(url, SessionID(id))
    }
  }
  router.post("/v1/worker/oidc-readiness") { request, _ in
    guard let url = try await audience(request) else { return invalid("an OIDC audience is an absolute http(s) URL") }
    return await answer { () -> Bool? in
      guard let ready = signing.oidcReadiness else { throw OIDCUnavailable() }
      try await ready(url)
      return true
    }
  }
  router.post("/v1/worker/session/:id/compact-claim") { request, parameters in
    guard let id = parameters["id"] else { return noSession() }
    let input = try await request.json(CompactClaimInput.self, dateDecodingStrategy: .deferredToDate)
    return await answer { try await owner.claimCompactRequest(SessionID(id), generation: input.generation) }
  }
  return router
}
