#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif

import ContentLane
import Fetch
import JSONValue
import Serve
import ServeSSE
import enum SpaceContract.ErrorCode
import struct SpaceContract.GroupID
import SpaceCore
import struct SpaceFS.Entry
import enum SpaceFS.FSResolveError
import struct SpaceFS.FSResolver
import SpaceTools
import Wuwei

// `viewer` resolves the caller only for a statement that calls `viewer()`, as
// the identity a watermark POST from the same credential would advance. A
// caller it refuses gets the refusal, never a NULL viewer.
func observeResponse(
  space: Space,
  url: URL,
  principal: Principal,
  viewer: () async throws -> IdentityVerdict? = { nil },
) async throws -> Response {
  let query = queryValues(of: url)
  switch (query["glob"], query["sql"]) {
  case let (glob?, nil):
    return try await watchResponse(space: space, glob: glob, from: query["from"], principal: principal, batch: query["batch"] == "1")
  case let (nil, sql?):
    // `params` is a JSON array bound to the statement's placeholders; `typed=1`
    // renders each snapshot in the typed rule (see QueryInput.typed).
    let parameters: [JSONValue]
    if let raw = query["params"] {
      guard case let .array(parsed)? = JSONValue.parse(raw) else {
        return errorResponse(.badRequest, code: "invalidArgument", message: "params must be a JSON array")
      }
      parameters = parsed
    } else {
      parameters = []
    }
    return try await snapshotsResponse(
      space: space, sql: sql, parameters: parameters, throttleMs: query["throttleMs"], principal: principal, viewer: viewer,
      render: query["typed"] == "1" ? Wire.typedQueryOutput : Wire.queryOutput,
    )
  default:
    return errorResponse(.badRequest, code: "invalidArgument", message: "observe takes exactly one of ?glob= or ?sql=[&params=][&typed=1][&throttleMs=]")
  }
}

/// File events under `glob` as SSE, resumed after `from` when given. Without
/// `from`, `head` opens the stream with an `event: head` frame naming the
/// revision the subscription starts after, so a client resumes from there.
func watchResponse(space: Space, glob: String, from rawFrom: String?, principal: Principal, head: Bool = false, batch: Bool = false) async throws -> Response {
  guard !glob.isEmpty else {
    return errorResponse(.badRequest, code: "invalidArgument", message: "glob must not be empty")
  }
  let from: Rev?
  if let raw = rawFrom {
    guard let parsed = Int(raw), parsed >= 0 else {
      return errorResponse(.badRequest, code: "invalidArgument", message: "from must be a non-negative integer")
    }
    from = Rev(parsed)
  } else {
    from = nil
  }
  let watched: WatchedGlob
  do {
    watched = try await WatchedGlob(glob, as: principal, in: space)
  } catch {
    if error is Evicted { throw error }
    return jsonResponse(Wire.failure(error).payload, status: error is SpaceError ? .notFound : .badRequest)
  }
  // The subscription starts after the revision the head frame names, so a
  // client resumes from it without missing or repeating a commit.
  let after: Rev
  if let from {
    after = from
  } else {
    do {
      after = Rev(try await space.currentRevision(in: watched.group))
    } catch {
      if error is Evicted { throw error }
      return jsonResponse(Wire.failure(error).payload, status: .internalServerError)
    }
  }
  var initial: SSEEvent?
  if head, from == nil {
    initial = .message(JSONValue.object(["rev": .integer(after.value)]).jsonString(), event: "head")
  }
  let events: AsyncStream<FSCommit>
  do {
    events = try await space.observeFS(glob: watched.pattern, from: after, group: watched.group, as: principal)
  } catch {
    if error is Evicted { throw error }
    return observationsUnavailable()
  }
  if batch {
    return .sse(initial: initial, forwarding: events) { commit in
      .message(JSONValue.object([
        "rev": .integer(commit.rev),
        "events": .array(commit.events.map { Wire.mutationJSON($0, prefix: watched.prefix) }),
      ]).jsonString(), event: "revision")
    }
  }
  return .sse(initial: initial, forwarding: events.mutations) { event in
    .message(Wire.mutationJSON(event, prefix: watched.prefix).jsonString())
  }
}

/// The space's observation job lives in another process: the streams it held closed at a drain, and the client reconnects instead of giving up.
func observationsUnavailable() -> Response {
  var response = errorResponse(
    .serviceUnavailable, code: ErrorCode.unavailable.rawValue, message: "this space's observation job is not hosted here — reconnect",
  )
  response.headers[.retryAfter] = "1"
  return response
}

/// `sql`'s snapshots as SSE, each rendered by `render`: the current result,
/// then each changed one.
func snapshotsResponse(
  space: Space,
  sql: String,
  parameters: [JSONValue],
  throttleMs rawThrottle: String?,
  principal: Principal,
  viewer: () async throws -> IdentityVerdict? = { nil },
  refusal: (any Error) throws -> Response = { error in
    if error is Evicted { throw error }
    return jsonResponse(Wire.failure(error).payload, status: .unprocessableContent)
  },
  render: @escaping @Sendable (Rows) -> JSONValue,
) async throws -> Response {
  let throttleMs: Int
  if let raw = rawThrottle {
    guard let parsed = Int(raw), parsed >= 0 else {
      return errorResponse(.badRequest, code: "invalidArgument", message: "throttleMs must be a non-negative integer")
    }
    throttleMs = parsed
  } else {
    throttleMs = 0
  }
  // Validate before committing to an SSE response: a rejected statement must
  // surface as an error status, not a 200 whose stream closes silently.
  do {
    _ = try Space.bound(parameters)
    try await space.validateQuery(sql, as: principal)
  } catch {
    return try refusal(error)
  }
  var identity: String?
  if Space.callsViewer(sql) {
    do {
      switch try await viewer() {
      case let .identity(name)?: identity = name
      case let .refused(response)?: return response
      case nil: identity = nil
      }
    } catch {
      if error is Evicted { throw error }
      return jsonResponse(Wire.failure(error).payload, status: .internalServerError)
    }
  }
  let snapshots: AsyncThrowingStream<Rows, any Error>
  do {
    snapshots = try space.observeRows(sql, parameters: parameters, throttle: .milliseconds(throttleMs), viewer: identity, as: principal)
  } catch {
    if error is Evicted { throw error }
    return observationsUnavailable()
  }
  return .sse(forwarding: snapshots) { rows in
    .message(render(rows).jsonString())
  }
}
