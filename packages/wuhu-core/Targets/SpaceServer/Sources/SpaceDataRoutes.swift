#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif

import Fetch
import HTTPTypes
import JSONValue
import OrderedCollections
import Serve
import SpaceContract
import SpaceCore
import struct SpaceFS.SpacePath
import SpaceTools

// `/_/space/*`: the data API a page's `wuhu:space` speaks. Reads
// pass the script wall of /_/query; writes take the stricter mutation
// admission below and act as the page's group minus admin.
func spaceDataResponse(
  space: Space,
  caller: WebCaller,
  dev: Bool,
  publicRead: Bool,
  route: String,
  request: Request,
) async throws -> Response {
  let query = queryValues(of: request.url)
  switch (route, request.method) {
  case ("query", .get), ("query", .head):
    let viewer: AccountID?
    switch try await scriptAdmission(space: space, caller: caller, dev: dev, publicRead: publicRead, request: request) {
    case let .refused(wall): return wall
    case let .admitted(account): viewer = account
    }
    guard let sql = query["sql"] else {
      return errorResponse(.badRequest, code: "invalidArgument", message: "query takes ?sql=[&params=]")
    }
    guard let parameters = boundParameters(query["params"]) else { return parametersRefusal() }
    let context = SpaceToolContext(space: space, principal: try await webPrincipal(viewer, group: caller.group, space: space))
    do {
      let output = try await context.typedQuery(sql, parameters: parameters)
      return revalidatedJSON(output, ifNoneMatch: request.headers[.ifNoneMatch]).viewed(by: viewer)
    } catch {
      return failureResponse(error).viewed(by: viewer)
    }
  case ("observe", .get):
    let viewer: AccountID?
    switch try await scriptAdmission(space: space, caller: caller, dev: dev, publicRead: publicRead, request: request) {
    case let .refused(wall): return wall
    case let .admitted(account): viewer = account
    }
    guard let sql = query["sql"] else {
      return errorResponse(.badRequest, code: "invalidArgument", message: "observe takes ?sql=[&params=][&throttleMs=]")
    }
    guard let parameters = boundParameters(query["params"]) else { return parametersRefusal() }
    let principal = try await webPrincipal(viewer, group: caller.group, space: space)
    return await snapshotsResponse(
      space: space, sql: sql, parameters: parameters, throttleMs: query["throttleMs"], principal: principal,
      refusal: failureResponse, render: Wire.typedQueryOutput,
    ).viewed(by: viewer)
  case ("watch", .get):
    let viewer: AccountID?
    switch try await scriptAdmission(space: space, caller: caller, dev: dev, publicRead: publicRead, request: request) {
    case let .refused(wall): return wall
    case let .admitted(account): viewer = account
    }
    guard let glob = query["glob"] else {
      return errorResponse(.badRequest, code: "invalidArgument", message: "watch takes ?glob=[&from=][&batch=1]")
    }
    let principal = try await webPrincipal(viewer, group: caller.group, space: space)
    return await watchResponse(space: space, glob: glob, from: query["from"], principal: principal, head: true, batch: query["batch"] == "1")
      .viewed(by: viewer)
  case ("attributes", .get), ("attributes", .head):
    let viewer: AccountID?
    switch try await scriptAdmission(space: space, caller: caller, dev: dev, publicRead: publicRead, request: request) {
    case let .refused(wall): return wall
    case let .admitted(account): viewer = account
    }
    guard let path = query["path"] else {
      return errorResponse(.badRequest, code: "invalidArgument", message: "attributes takes ?path=")
    }
    let context = SpaceToolContext(space: space, principal: try await webPrincipal(viewer, group: caller.group, space: space))
    return await toolResponse(context, "attributes.read", input: .object(["path": .string(path)])).viewed(by: viewer)
  case ("find", .get), ("find", .head), ("grep", .get), ("grep", .head):
    let viewer: AccountID?
    switch try await scriptAdmission(space: space, caller: caller, dev: dev, publicRead: publicRead, request: request) {
    case let .refused(wall): return wall
    case let .admitted(account): viewer = account
    }
    let key = route == "find" ? "glob" : "pattern"
    guard let input = searchInput(key, query) else {
      return errorResponse(
        .badRequest, code: "invalidArgument",
        message: "\(route) takes ?\(key)=[&path=][&matchLimit=][&hidden=][&noIgnore=][&step=], matchLimit an integer, hidden and noIgnore true or false",
      )
    }
    let context = SpaceToolContext(space: space, principal: try await webPrincipal(viewer, group: caller.group, space: space))
    return await toolResponse(context, route, input: input).viewed(by: viewer)
  case ("rows", .post):
    let write: PageWrite
    switch try await writeAdmission(space: space, caller: caller, dev: dev, request: request) {
    case let .refused(wall): return wall
    case let .admitted(admitted): write = admitted
    }
    guard case let .string(path)? = write.body["path"] else {
      return errorResponse(.badRequest, code: "invalidArgument", message: "rows takes {path, ops, page}")
    }
    do {
      let edits = try RowEdit.parse(write.body["ops"] ?? .null)
      let commit = try await write.context.commitRows(path, edits: edits)
      let output: JSONValue = .object(["rev": .integer(commit.rev.value), "ids": .array(commit.ids.map { .integer(Int($0)) })])
      return jsonResponse(output).viewed(by: write.viewer.account)
    } catch {
      return failureResponse(error).viewed(by: write.viewer.account)
    }
  case ("attributes", .post):
    let write: PageWrite
    switch try await writeAdmission(space: space, caller: caller, dev: dev, request: request) {
    case let .refused(wall): return wall
    case let .admitted(admitted): write = admitted
    }
    var input = write.body
    input.removeValue(forKey: "page")
    return await toolResponse(write.context, "attributes.patch", input: .object(input)).viewed(by: write.viewer.account)
  case ("query", _), ("observe", _), ("watch", _), ("rows", _), ("attributes", _), ("find", _), ("grep", _):
    return plainStatus(.methodNotAllowed)
  default:
    return plainStatus(.notFound)
  }
}

/// `params` is one JSON array of bound values; absent means none.
private func boundParameters(_ raw: String?) -> [JSONValue]? {
  guard let raw else { return [] }
  guard case let .array(values)? = JSONValue.parse(raw) else { return nil }
  return values
}

/// The find or grep tool's input from a page's query string; nil when the
/// glob or pattern is missing, the limit is not an integer or a flag is not
/// `true` or `false`. The context has
/// no machine seam, so a `machines://` path is the tool's `unavailable`.
private func searchInput(_ key: String, _ query: [String: String]) -> JSONValue? {
  guard let value = query[key] else { return nil }
  var input: OrderedDictionary<String, JSONValue> = [key: .string(value)]
  if let path = query["path"] { input["path"] = .string(path) }
  if let raw = query["matchLimit"] {
    guard let limit = Int(raw) else { return nil }
    input["matchLimit"] = .integer(limit)
  }
  for name in ["hidden", "noIgnore"] {
    guard let raw = query[name] else { continue }
    guard let flag = Bool(raw) else { return nil }
    input[name] = .bool(flag)
  }
  if let step = query["step"] { input["step"] = .string(step) }
  return .object(input)
}

private func parametersRefusal() -> Response {
  errorResponse(.badRequest, code: "invalidArgument", message: "params must be a JSON array of bound values")
}

private func toolResponse(_ context: SpaceToolContext, _ name: String, input: JSONValue) async -> Response {
  let tool = SpaceToolbox.all.first { $0.name == name }!
  do {
    return jsonResponse(try await tool.run(context, input: input))
  } catch {
    return failureResponse(error)
  }
}

private func failureResponse(_ error: any Error) -> Response {
  let failure = Wire.failure(error)
  switch failure {
  case .undecodableInput:
    return jsonResponse(failure.payload, status: .badRequest)
  case let .failed(code, _, _, _):
    return jsonResponse(failure.payload, status: status(of: code))
  }
}

private func status(of code: ErrorCode) -> Status {
  switch code {
  case .notFound: .notFound
  case .conflict, .aliasTaken: .conflict
  case .invalidPath, .invalidArgument, .invalidAlias, .byteLimitExceeded: .badRequest
  case .unauthorized, .forbidden, .memberRequired: .forbidden
  case .unsupported, .unknownKind: .unprocessableContent
  case .unavailable: .serviceUnavailable
  case .internal: .internalServerError
  case .capabilityInvalidArgument, .unsupportedFeature: .badRequest
  case .providerAuth: .badGateway
  case .providerRegion, .providerEntitlement: .forbidden
  case .providerRateLimited: .tooManyRequests
  case .providerNotConfigured, .providerUnavailable: .serviceUnavailable
  }
}

/// An admitted page write: who is viewing, the JSON body, and the context
/// that acts as the page.
struct PageWrite {
  let viewer: Person
  let body: OrderedDictionary<String, JSONValue>
  let context: SpaceToolContext
}

enum WriteAdmission {
  case admitted(PageWrite)
  case refused(Response)
}

private let maximumPageWriteBytes = 4 << 20

// A write is a JSON POST from the page's own origin, which a form or a
// cross-site script cannot forge, with a live read session: --public-read
// admits no visitor to write, and --dev admits its seat.
func writeAdmission(space: Space, caller: WebCaller, dev: Bool, request: Request) async throws -> WriteAdmission {
  let mediaType = request.headers[.contentType]?.split(separator: ";").first?.trimmingCharacters(in: .whitespaces).lowercased()
  guard mediaType == "application/json" else {
    return .refused(errorResponse(.unsupportedMediaType, code: "invalidArgument", message: "page writes take an application/json body"))
  }
  guard let origin = request.headers[originField], caller.contentOrigins.contains(origin),
        request.headers[secFetchSiteField] == "same-origin"
  else {
    return .refused(errorResponse(
      .forbidden, code: "crossOrigin", message: "page writes are accepted only from this host's own pages",
    ))
  }
  let viewer: AccountID?
  if dev {
    viewer = nil
  } else {
    switch try await cookieAdmission(space: space, group: caller.group, cookies: caller.cookies, request: request) {
    case let .refused(wall): return .refused(wall)
    case let .admitted(account): viewer = account
    }
  }
  let data: Data
  do {
    data = try await request.body?.data(upTo: maximumPageWriteBytes) ?? Data()
  } catch {
    return .refused(errorResponse(
      .contentTooLarge, code: "invalidArgument", message: "request body exceeds the \(maximumPageWriteBytes)-byte page write bound",
    ))
  }
  guard case let .object(body)? = JSONValue.parse(String(decoding: data, as: UTF8.self)) else {
    return .refused(errorResponse(.badRequest, code: "invalidArgument", message: "request body is not a JSON object"))
  }
  guard case let .string(raw)? = body["page"], let page = pagePath(raw) else {
    return .refused(errorResponse(
      .badRequest, code: "invalidArgument", message: "page writes carry page: the writing page's own path",
      hint: "send location.pathname",
    ))
  }
  let acting = Page(path: page, viewer: try await webPerson(viewer, group: caller.group, space: space))
  return .admitted(PageWrite(viewer: acting.viewer, body: body, context: SpaceToolContext(space: space, principal: acting.principal)))
}

/// A page's `location.pathname`: hostless and absolute, percent-decoded, a
/// directory's trailing slash dropped.
func pagePath(_ raw: String) -> SpacePath? {
  guard raw.hasPrefix("/"), !raw.hasPrefix("//"), let decoded = raw.removingPercentEncoding else { return nil }
  let trimmed = decoded.count > 1 && decoded.hasSuffix("/") ? String(decoded.dropLast()) : decoded
  return try? SpacePath(validating: trimmed)
}

private let originField = HTTPField.Name("Origin")!
private let secFetchSiteField = HTTPField.Name("Sec-Fetch-Site")!
