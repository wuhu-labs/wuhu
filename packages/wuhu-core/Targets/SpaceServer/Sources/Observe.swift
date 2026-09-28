#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif

import Fetch
import JSONValue
import Serve
import ServeSSE
import struct SpaceContract.GroupID
import SpaceCore
import struct SpaceFS.Entry
import enum SpaceFS.FSResolveError
import struct SpaceFS.FSResolver
import SpaceTools

// `viewer` resolves the caller only for a statement that calls `viewer()`, as
// the identity a watermark POST from the same credential would advance. A
// caller it refuses gets the refusal, never a NULL viewer.
func observeResponse(
  space: Space,
  url: URL,
  principal: Principal,
  viewer: () async throws -> IdentityVerdict? = { nil },
) async -> Response {
  let query = queryValues(of: url)
  switch (query["glob"], query["sql"]) {
  case let (glob?, nil):
    return await watchResponse(space: space, glob: glob, from: query["from"], principal: principal)
  case let (nil, sql?):
    return await snapshotsResponse(
      space: space, sql: sql, parameters: [], throttleMs: query["throttleMs"], principal: principal, viewer: viewer,
      render: Wire.queryOutput,
    )
  default:
    return errorResponse(.badRequest, code: "invalidArgument", message: "observe takes exactly one of ?glob= or ?sql=[&throttleMs=]")
  }
}

/// File events under `glob` as SSE, resumed after `from` when given. Without
/// `from`, `head` opens the stream with an `event: head` frame naming the
/// revision the subscription starts after, so a client resumes from there.
func watchResponse(space: Space, glob: String, from rawFrom: String?, principal: Principal, head: Bool = false) async -> Response {
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
    return jsonResponse(Wire.failure(error).payload, status: error is SpaceError ? .notFound : .badRequest)
  }
  let events = await space.observeFS(glob: watched.pattern, from: from, group: watched.group)
  var initial: SSEEvent?
  if head, from == nil {
    do {
      initial = .message(JSONValue.object(["rev": .integer(try await space.currentRevision())]).jsonString(), event: "head")
    } catch {
      return jsonResponse(Wire.failure(error).payload, status: .internalServerError)
    }
  }
  return .sse(initial: initial, forwarding: events) { event in
    .message(Wire.mutationJSON(event, prefix: watched.prefix).jsonString())
  }
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
  refusal: (any Error) -> Response = { jsonResponse(Wire.failure($0).payload, status: .unprocessableContent) },
  render: @escaping @Sendable (Rows) -> JSONValue,
) async -> Response {
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
    return refusal(error)
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
      return jsonResponse(Wire.failure(error).payload, status: .internalServerError)
    }
  }
  let snapshots = await space.observeQuery(
    sql, parameters: parameters, throttle: .milliseconds(throttleMs), viewer: identity, as: principal,
  )
  return .sse(forwarding: snapshots) { rows in
    .message(render(rows).jsonString())
  }
}
