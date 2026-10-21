#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import struct Credentials.CredentialResolver
import Dependencies
import Fetch
import FetchSSE
import struct InferenceKit.AttemptTraceClient
import JSONValue
import MainHub
import SessionDomain
import SpaceCore

/// Main's answer a worker route refused: its status and the `{code, message}`
/// it sent.
public struct MainFailure: Error, CustomStringConvertible, Sendable {
  public let status: Int
  public let code: String?
  public let message: String
  public var description: String { message }
}

/// The loop's journal and queue as the worker reaches them: `Main` over the
/// worker's line to main's API, with the worker's own token. Every call is
/// one route; `pendingArrivals` is the route's SSE stream. Dates cross as the
/// store writes them (`JSONEncoder`'s default), never re-based.
public struct MainClient: Main {
  private let connection: MainConnection
  private let credential: @Sendable () async throws -> String

  public init(connection: MainConnection, credential: @escaping @Sendable () async throws -> String) {
    self.connection = connection
    self.credential = credential
  }

  private struct Reply<Value: Codable>: Codable { var value: Value? }
  private struct CompactClaimInput: Codable { var generation: Int }
  private struct WakeAt: Codable { var at: Double? }
  private struct CacheWarming: Codable { var intervalSeconds: Int }
  private struct Audience: Codable { var audience: String }

  private func fetch(_ method: Fetch.Method, _ path: String, body: Body? = nil) async throws -> Response {
    guard let url = URL(string: "http://main" + path) else { preconditionFailure("a worker route is a path: \(path)") }
    var request = Request(url: url, method: method, body: body)
    request.headers[.authorization] = "Bearer " + (try await credential())
    return try await connection.fetch(request)
  }

  // Main's refusal, typed where the worker acts on the kind: a session whose
  // stored data main cannot read is `SessionError.unreadableData`.
  private static func failure(_ response: Response, session: SessionID?) async -> any Error {
    let bytes = (try? await response.body.data()) ?? Data()
    let object = JSONValue.parse(String(decoding: bytes, as: UTF8.self))?.object
    let code = object?["code"]?.stringValue
    if code == "unreadableSessionData", let session { return SessionError.unreadableData(session) }
    return MainFailure(
      status: response.status.code, code: code,
      message: object?["message"]?.stringValue ?? "main answered \(response.status.code)",
    )
  }

  private func call<Value: Codable>(_ method: Fetch.Method, _ path: String, body: Body? = nil, session: SessionID? = nil) async throws -> Value? {
    let response = try await fetch(method, path, body: body)
    guard 200 ..< 300 ~= response.status.code else { throw await Self.failure(response, session: session) }
    return try await response.body.json(Reply<Value>.self, dateDecodingStrategy: .deferredToDate).value
  }

  private func require<Value: Codable>(_ method: Fetch.Method, _ path: String, body: Body? = nil, session: SessionID? = nil) async throws -> Value {
    guard let value: Value = try await call(method, path, body: body, session: session) else {
      throw MainFailure(status: 200, code: "internal", message: "main answered \(path) with no value")
    }
    return value
  }

  private func session(_ id: SessionID, _ leaf: String) -> String { "/v1/worker/session/\(id.rawValue)/\(leaf)" }

  public func owedExecs(_ session: SessionID) async throws -> [ExecRecord] { try await require(.get, self.session(session, "owed-execs")) }

  public func pendingArrivals(_ session: SessionID) -> AsyncThrowingStream<[PendingArrival], any Error> {
    let path = self.session(session, "arrivals")
    let clock: any Clock<Duration> = Dependency(\.continuousClock).wrappedValue
    return AsyncThrowingStream { continuation in
      let task = Task {
        // Once open, a stream main cuts (as it reboots) is opened again;
        // main refusing it, or the first open failing, ends it.
        var opened = false
        while !Task.isCancelled {
          do {
            let response = try await fetch(.get, path)
            guard 200 ..< 300 ~= response.status.code else { throw await Self.failure(response, session: session) }
            opened = true
            let decoder = JSONDecoder()
            for try await event in response.sse() {
              continuation.yield(try decoder.decode([PendingArrival].self, from: Data(event.data.utf8)))
            }
          } catch {
            guard opened, !(error is MainFailure), !(error is DecodingError) else { return continuation.finish(throwing: error) }
          }
          try? await clock.sleep(for: .milliseconds(200))
        }
        continuation.finish()
      }
      continuation.onTermination = { _ in task.cancel() }
    }
  }

  public func append(_ session: SessionID, _ event: SessionEvent) async throws -> MainReply {
    try await require(.post, self.session(session, "events"), body: try Body.json(event, dateEncodingStrategy: .deferredToDate))
  }

  public func modelRoute(_ session: SessionID) async throws -> SessionModelRoute? { try await call(.get, self.session(session, "route")) }
  public func record(_ session: SessionID) async throws -> SessionRecord { try await require(.get, self.session(session, "record"), session: session) }
  public func hydrate(_ session: SessionID) async throws -> SessionHydration { try await require(.get, self.session(session, "hydration"), session: session) }
  public func queueHead(_ session: SessionID) async throws -> Int { try await require(.get, self.session(session, "queue-head")) }
  public func pendingCommand(_ session: SessionID) async throws -> SessionCommand? { try await call(.get, self.session(session, "command")) }
  public func registeredSubscriptions(_ session: SessionID) async throws -> RegisteredSubscriptions {
    try await require(.get, self.session(session, "subscriptions"))
  }

  /// The token the worker's tools present as the session.
  public func sessionToken(_ session: SessionID) async throws -> String { try await require(.get, self.session(session, "token")) }

  /// Wakes the session's parked loop at `due` if nothing else does; nil clears it.
  public func scheduleWake(_ session: SessionID, at due: Date?) async throws {
    let _: Bool? = try await call(.post, self.session(session, "wake-at"), body: try Body.json(WakeAt(at: due?.timeIntervalSince1970)))
  }

  public func allowsCacheWarming(_ session: SessionID) async throws -> Bool { try await require(.get, self.session(session, "cache-warming")) }

  public func scheduleCacheWarming(_ session: SessionID, intervalSeconds: Int) async throws {
    let _: Bool? = try await call(.post, self.session(session, "cache-warming"), body: try Body.json(CacheWarming(intervalSeconds: intervalSeconds)))
  }

  /// Main signs for the worker's inferences: an OIDC token for the session
  /// at `audience`, the provider's readiness, and the identity a replay binds to.
  public func oidcToken(_ session: SessionID, audience: URL) async throws -> String {
    try await require(.post, self.session(session, "oidc-token"), body: try Body.json(Audience(audience: audience.absoluteString)))
  }

  public func oidcReadiness(audience: URL) async throws {
    let _: Bool? = try await call(.post, "/v1/worker/oidc-readiness", body: try Body.json(Audience(audience: audience.absoluteString)))
  }

  public func oidcBindingIdentity(_ session: SessionID, audience: URL) async throws -> String? {
    try await call(.post, self.session(session, "oidc-binding"), body: try Body.json(Audience(audience: audience.absoluteString)))
  }

  /// The access a worker in its own process brings to its inferences:
  /// `credentials` of its own, OIDC signed by main.
  public func inferenceAccess(credentials: CredentialResolver, trace: AttemptTraceClient?) -> InferenceAccess {
    InferenceAccess(
      credentials: credentials,
      oidcToken: { audience, session in try await oidcToken(session, audience: audience) },
      oidcReadiness: { audience in try await oidcReadiness(audience: audience) },
      oidcBindingIdentity: { audience, session in try await oidcBindingIdentity(session, audience: audience) },
      trace: trace,
    )
  }

  public func drainQueue(_ session: SessionID) async throws -> QueueDrain { try await require(.post, self.session(session, "drain")) }
  public func claimCompactRequest(_ session: SessionID, generation: Int) async throws -> CompactRequestClaim? {
    try await call(.post, self.session(session, "compact-claim"), body: try Body.json(CompactClaimInput(generation: generation), dateEncodingStrategy: .deferredToDate))
  }
}
