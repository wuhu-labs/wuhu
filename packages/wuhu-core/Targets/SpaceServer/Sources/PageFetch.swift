#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import AsyncHTTPClient
import Dependencies
import Dispatch
import Fetch
import HTTPTypes
import JSONValue
import NIOCore
import NIOHTTP1
import Serve
import SpaceCore

typealias PageFetchHandler = @Sendable (Request, Set<String>, String, String, String, String, NIODeadline) async throws -> Response

struct PageFetch: Sendable {
  let identity: ServerIdentity
  let issuer: String?
  var hop: @Sendable (Request, NIODeadline) async throws -> Response = { try await pinnedPageFetch($0, deadline: $1) }

  func response(_ request: Request, allow: Set<String>, space: String, group: String, page: String, viewer: String, deadline: NIODeadline) async throws -> Response {
    @Dependency(\.date) var date
    @Dependency(\.uuid) var uuid
    var target = request
    for count in 0 ... 20 {
      guard let origin = fetchOrigin(target.url), allow.contains(origin) else {
        throw PageFetchError(code: "fetchOriginForbidden", message: "the target origin is not listed in /fetch.json", status: .forbidden)
      }
      guard NIODeadline.now() < deadline else { throw PageFetchError.timeout }
      do {
        target.headers[.authorization] = "Bearer " + (try identity.token(
          issuer: issuer, audience: target.url, space: space, group: group, now: date.now, id: uuid(),
          lifetime: 60, page: page, viewer: viewer,
        ))
      } catch {
        throw PageFetchError(code: "fetchIdentityUnavailable", message: "the server could not mint the fetch identity token", status: .serviceUnavailable)
      }
      var response = try await hop(target, deadline)
      response.headers[.setCookie] = nil
      if [301, 302, 303, 307, 308].contains(response.status.code), let location = response.headers[.location] {
        guard count < 20, let url = URL(string: location, relativeTo: target.url)?.absoluteURL, fetchOrigin(url) != nil else {
          throw PageFetchError(code: "fetchRedirectInvalid", message: "invalid redirect or redirect limit exceeded", status: .badGateway)
        }
        // Check before reading a redirect body or making any connection to its destination.
        guard allow.contains(fetchOrigin(url)!) else {
          throw PageFetchError(code: "fetchOriginForbidden", message: "the redirect origin is not listed in /fetch.json", status: .forbidden)
        }
        target.url = url
        if (response.status.code == 303 && target.method != .head) || ([301, 302].contains(response.status.code) && target.method == .post) {
          target.method = .get
          target.body = nil
          target.headers[.contentType] = nil
          target.headers[.contentLength] = nil
        }
        continue
      }
      response.headers[HTTPField.Name("Wuhu-Fetch-Result")!] = "upstream"
      return response
    }
    preconditionFailure()
  }
}

struct PageFetchError: Error, Sendable {
  let code: String
  let message: String
  let status: Status
  static let timeout = Self(code: "fetchTimeout", message: "proxied fetch exceeded its 60 s total time limit", status: .gatewayTimeout)
}

func pageFetchResponse(space: Space, caller: WebCaller, proxy: PageFetchHandler?, request: Request, deadline: NIODeadline = .now() + .seconds(60), spaceIdentity: @Sendable (Space) async throws -> String = { try await $0.identity().rawValue }) async -> Response {
  do {
    guard request.method == .post else {
      throw PageFetchError(code: "fetchMethodInvalid", message: "proxied fetch uses POST /_/space/fetch", status: .methodNotAllowed)
    }
    guard let origin = request.headers[.origin], caller.contentOrigins.contains(origin),
          request.headers[HTTPField.Name("Sec-Fetch-Site")!] == "same-origin"
    else { return closedFetchResponse(crossOriginRefusal()) }
    let account: AccountID
    switch try await cookieAdmission(space: space, group: caller.group, cookies: caller.cookies, request: request) {
    case let .admitted(viewer?): account = viewer
    default:
      throw PageFetchError(code: "fetchViewerRequired", message: "proxied fetch requires a signed-in viewer; anonymous viewers cannot fetch", status: .unauthorized)
    }
    let query = queryValues(of: request.url)
    guard let raw = query["url"], let url = URL(string: raw), fetchOrigin(url) != nil,
          let pageRaw = query["page"], let page = pagePath(pageRaw)
    else { throw PageFetchError(code: "fetchInvalidArgument", message: "fetch takes an absolute HTTP(S) URL and the page's own path", status: .badRequest) }
    guard let method = Method(rawValue: query["method"] ?? "GET"), [Method.get, .post, .put, .patch, .delete, .head].contains(method) else {
      throw PageFetchError(code: "fetchMethodInvalid", message: "fetch supports GET, POST, PUT, PATCH, DELETE and HEAD", status: .badRequest)
    }
    var headers = Headers()
    guard case let .object(fields)? = JSONValue.parse(query["headers"] ?? "{}") else {
      throw PageFetchError(code: "fetchInvalidArgument", message: "fetch headers must be a JSON object", status: .badRequest)
    }
    for (name, value) in fields {
      guard let field = HTTPField.Name(name), case let .string(text) = value else {
        throw PageFetchError(code: "fetchInvalidArgument", message: "invalid fetch header", status: .badRequest)
      }
      if field == .authorization {
        throw PageFetchError(code: "fetchAuthorizationForbidden", message: "a page cannot set Authorization on proxied fetch", status: .forbidden)
      }
      if !hopHeaders.contains(name.lowercased()), field != .cookie, name.lowercased() != "host" { headers[field] = text }
    }
    let fs = await space.fs(caller.group)
    guard let (_, listData) = try? await fs.read("/fetch.json"),
          case let .object(config)? = JSONValue.parse(String(decoding: listData, as: UTF8.self)),
          case let .array(entries)? = config["allow"], !entries.isEmpty
    else { throw PageFetchError(code: "fetchListMissing", message: "/fetch.json is missing or has an empty allow list", status: .forbidden) }
    var allow = Set<String>()
    for entry in entries {
      guard case let .string(raw) = entry, let url = URL(string: raw), let origin = fetchOrigin(url),
            let parts = URLComponents(url: url, resolvingAgainstBaseURL: false), (parts.path.isEmpty || parts.path == "/"), parts.query == nil, parts.fragment == nil
      else { throw PageFetchError(code: "fetchListInvalid", message: "/fetch.json allow entries must be exact HTTP(S) origins without paths or wildcards", status: .badRequest) }
      allow.insert(origin)
    }
    guard allow.contains(fetchOrigin(url)!) else {
      throw PageFetchError(code: "fetchOriginForbidden", message: "the target origin is not listed in /fetch.json", status: .forbidden)
    }
    guard let proxy else {
      throw PageFetchError(code: "fetchIdentityUnavailable", message: "the server fetch identity is unavailable", status: .serviceUnavailable)
    }
    let data: Data
    do {
      data = try await fetchWithinDeadline(deadline) { try await request.body?.data(upTo: 10 << 20) ?? Data() }
    } catch let error as PageFetchError { throw error } catch {
      throw PageFetchError(code: "fetchBodyTooLarge", message: "proxied fetch request body exceeds 10 MiB", status: .contentTooLarge)
    }
    let viewer = try await space.persona(account: account)?.name ?? account.rawValue
    let outgoing = Request(url: url, method: method, headers: headers, body: data.isEmpty ? nil : .bytes(data))
    let spaceID: String
    do { spaceID = try await spaceIdentity(space) } catch {
      throw PageFetchError(code: "fetchIdentityUnavailable", message: "the server fetch identity is unavailable", status: .serviceUnavailable)
    }
    let allowedOrigins = allow
    let response = try await fetchWithinDeadline(deadline) {
      try await proxy(
        outgoing, allowedOrigins, spaceID, caller.group.rawValue, page.rawValue, viewer, deadline,
      )
    }
    return response.viewed(by: account)
  } catch let error as PageFetchError {
    return closedFetchResponse(errorResponse(error.status, code: error.code, message: error.message))
  } catch {
    return closedFetchResponse(errorResponse(.badGateway, code: "fetchUpstreamUnavailable", message: "the proxied backend could not be reached"))
  }
}

private let hopHeaders: Set<String> = ["connection", "keep-alive", "proxy-authenticate", "proxy-authorization", "te", "trailer", "transfer-encoding", "upgrade", "content-length"]

func fetchOrigin(_ url: URL) -> String? {
  guard var parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
        let scheme = parts.scheme?.lowercased(), ["http", "https"].contains(scheme),
        let host = parts.host?.lowercased(), !host.isEmpty, !host.contains("*"), parts.user == nil, parts.password == nil,
        parts.port == nil || (1 ... 65535).contains(parts.port!)
  else { return nil }
  parts.scheme = scheme
  parts.host = host
  if (scheme == "https" && parts.port == 443) || (scheme == "http" && parts.port == 80) { parts.port = nil }
  parts.path = ""
  parts.query = nil
  parts.fragment = nil
  return parts.string
}

private func fetchWithinDeadline<T: Sendable>(_ deadline: NIODeadline, operation: @escaping @Sendable () async throws -> T) async throws -> T {
  @Dependency(\.continuousClock) var clock
  return try await withThrowingTaskGroup(of: T.self) { tasks in
    tasks.addTask { try await operation() }
    tasks.addTask { [clock] in
      try await clock.sleep(for: .nanoseconds(max(0, (deadline - .now()).nanoseconds)))
      throw PageFetchError.timeout
    }
    defer { tasks.cancelAll() }
    return try await tasks.next()!
  }
}

func pinnedPageFetch(_ request: Request, deadline: NIODeadline, resolve: @Sendable (String, Int) async throws -> SocketAddress = resolveFetchHost) async throws -> Response {
  let rawHost = request.url.host!
  let host = rawHost.hasPrefix("[") ? String(rawHost.dropFirst().dropLast()) : rawHost
  let address = try await resolve(host, request.url.port ?? (request.url.scheme == "https" ? 443 : 80))
  var configuration = HTTPClient.Configuration(redirectConfiguration: .disallow)
  configuration.dnsOverride = [host: address.ipAddress!]
  let lease = FetchConnection(configuration: configuration, deadline: deadline)
  var upstream = HTTPClientRequest(url: request.url.absoluteString)
  upstream.method = HTTPMethod(rawValue: request.method.rawValue)
  for field in request.headers.fields { upstream.headers.add(name: field.name.rawName, value: field.value) }
  if let body = request.body { upstream.body = .bytes(ByteBuffer(bytes: try await body.bytes())) }
  let response: HTTPClientResponse
  do { response = try await lease.client.execute(upstream, deadline: deadline) } catch {
    if .now() >= deadline || (error as? HTTPClientError) == .deadlineExceeded { throw PageFetchError.timeout }
    throw error
  }
  var headers = Headers()
  let nominated = Set((response.headers.first(name: "connection") ?? "").lowercased().split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) })
  for (name, value) in response.headers where !hopHeaders.contains(name.lowercased()) && !nominated.contains(name.lowercased()) && name.lowercased() != "set-cookie" {
    if let field = HTTPField.Name(name) { headers.append(HTTPField(name: field, value: value)) }
  }
  return Response(status: Status(code: Int(response.status.code)), headers: headers, body: .stream(FetchResponseStream(body: response.body, lease: lease, deadline: deadline)))
}

private final class FetchConnection: Sendable {
  let client: HTTPClient
  let timeout: Scheduled<Void>
  init(configuration: HTTPClient.Configuration, deadline: NIODeadline) {
    let client = HTTPClient(eventLoopGroupProvider: .singleton, configuration: configuration)
    self.client = client
    timeout = client.eventLoopGroup.any().scheduleTask(deadline: deadline) { client.shutdown { _ in } }
  }

  deinit {
    timeout.cancel()
    client.shutdown { _ in }
  }
}

private struct FetchResponseStream: AsyncSequence, Sendable {
  typealias Element = Bytes
  let body: HTTPClientResponse.Body
  let lease: FetchConnection
  let deadline: NIODeadline
  func makeAsyncIterator() -> Iterator { Iterator(base: body.makeAsyncIterator(), lease: lease, deadline: deadline) }
  struct Iterator: AsyncIteratorProtocol {
    var base: HTTPClientResponse.Body.AsyncIterator
    let lease: FetchConnection
    let deadline: NIODeadline
    mutating func next() async throws -> Bytes? {
      guard .now() < deadline else { throw PageFetchError.timeout }
      guard let buffer = try await base.next() else { lease.timeout.cancel(); lease.client.shutdown { _ in }; return nil }
      return Data(buffer.readableBytesView)
    }
  }
}

private func resolveFetchHost(_ host: String, _ port: Int) async throws -> SocketAddress {
  let (stream, continuation) = AsyncThrowingStream<SocketAddress, any Error>.makeStream(bufferingPolicy: .bufferingNewest(1))
  DispatchQueue.global().async {
    do {
      continuation.yield(try SocketAddress.makeAddressResolvingHost(host, port: port))
      continuation.finish()
    } catch { continuation.finish(throwing: error) }
  }
  var iterator = stream.makeAsyncIterator()
  guard let address = try await iterator.next() else { throw CancellationError() }
  return address
}

private func closedFetchResponse(_ response: Response) -> Response {
  var response = response
  response.headers[HTTPField.Name("Connection")!] = "close"
  return response
}
