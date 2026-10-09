#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif

import Crypto
import Fetch
import HTTPTypes
import JSONValue
import Serve
import struct SessionDomain.ConversationID
import struct SpaceContract.GroupID
import enum SpaceContract.MediaType
import SpaceCore
import SpaceFS
import SpaceTools

func webResponse(
  space: Space,
  group: GroupID,
  contentHost: ContentHost,
  advertisedOrigin: String?,
  now: Date,
  dev: Bool,
  publicRead: Bool,
  views: ViewProviders?,
  shell: ShellSDK?,
  pageFetch: PageFetchHandler? = nil,
  request: Request,
) async throws -> Response {
  let pairs = pairedOrigins(request: request, contentHost: contentHost, advertisedOrigin: advertisedOrigin)
  let paired = allowedOrigin(request: request, pairs: pairs)
  var response: Response
  if group != .shared, try await !space.groupExists(group) {
    response = errorResponse(.notFound, code: "unknownGroup", message: "this space has no group \(group.rawValue)")
  } else {
    response = try await routedWebResponse(
      space: space,
      caller: WebCaller(
        group: group, crossOrigin: crossOrigin(request, paired: paired != nil),
        contentOrigins: contentOrigins(request: request), webApp: contentHost.origin,
        cookies: contentHost.pattern == nil ? .legacy : .hostOnly,
      ),
      now: now,
      dev: dev,
      publicRead: publicRead,
      views: views,
      shell: shell,
      pageFetch: pageFetch,
      request: request,
    )
  }
  response.headers[.vary] = request.method == .options
    ? "Origin, Access-Control-Request-Method, Access-Control-Request-Headers"
    : "Origin"
  if let origin = paired {
    response.headers[.accessControlAllowOrigin] = origin
    response.headers[.accessControlAllowCredentials] = "true"
    if request.method == .options {
      response.headers[.accessControlAllowMethods] = "GET, POST, DELETE"
      response.headers[.accessControlAllowHeaders] = "Authorization"
    }
  }
  // Sibling hosts are same-site: only the host itself and the SPAs it pairs
  // with may frame a group's pages, even by a navigation the cookie wall lets
  // through.
  if group != .shared {
    let framing = (["frame-ancestors 'self'"] + pairs.map(\.serialized)).joined(separator: " ")
    response.headers[contentSecurityPolicy] = [response.headers[contentSecurityPolicy], framing]
      .compactMap(\.self).joined(separator: "; ")
  }
  return response
}

private let contentSecurityPolicy = HTTPField.Name("Content-Security-Policy")!

// Browsers require CORS for cross-origin font fetches and the credentialed
// /_/session bootstrap, so this reflection carries Allow-Credentials: true.
// A group host `<g>.<host>` pairs with the bare host, where the SPA of every
// group a person reads runs: the advertised --origin (the browser origin
// behind a TLS-terminating proxy) and the bare host at this request's own
// scheme and port. Reflecting only that pairing keeps space content
// unreadable to arbitrary websites. Match is exact on scheme+host+effective
// port — never widen to *, a suffix/prefix match, or a sibling group host,
// or any website could read space content with the visitor's read-session
// cookie.
private func allowedOrigin(request: Request, pairs: [OriginEndpoint]) -> String? {
  guard let origin = request.headers[.origin],
        let requester = URL(string: origin).flatMap(originEndpoint),
        pairs.contains(requester)
  else { return nil }
  return origin
}

private func pairedOrigins(request: Request, contentHost: ContentHost, advertisedOrigin: String?) -> [OriginEndpoint] {
  var pairs: [OriginEndpoint] = []
  if let advertised = advertisedOrigin.flatMap(URL.init(string:)).flatMap(originEndpoint) { pairs.append(advertised) }
  if let own = originEndpoint(request.url) {
    // Without --origin the web app is also opened by loopback address.
    let hosts = [contentHost.host] + (advertisedOrigin == nil ? ["127.0.0.1", "::1"] : [])
    for host in hosts {
      let bare = OriginEndpoint(scheme: own.scheme, host: host, port: own.port)
      if !pairs.contains(bare) { pairs.append(bare) }
    }
  }
  return pairs
}

private struct OriginEndpoint: Equatable {
  let scheme: String
  let host: String
  let port: Int

  var serialized: String {
    let defaultPort = scheme == "https" ? 443 : 80
    let name = host.contains(":") ? "[\(host)]" : host
    return port == defaultPort ? "\(scheme)://\(name)" : "\(scheme)://\(name):\(port)"
  }
}

private func originEndpoint(_ url: URL) -> OriginEndpoint? {
  guard let scheme = url.scheme, let host = url.host else { return nil }
  let bare = host.hasPrefix("[") && host.hasSuffix("]") ? String(host.dropFirst().dropLast()) : host
  return OriginEndpoint(scheme: scheme, host: bare.lowercased(), port: url.port ?? (scheme == "https" ? 443 : 80))
}

/// The content origin a page on this host has, in its serialized form.
private func contentOrigins(request: Request) -> [String] {
  originEndpoint(request.url).map { [$0.serialized] } ?? []
}

/// The group a web request reads, from its Host, whether its caller is a
/// cross-origin script the cookie must not serve, and the origin a page on
/// this host has.
enum ContentCookies {
  case legacy
  case hostOnly

  var read: String { self == .legacy ? "wuhu_read" : "__Host-wuhu_read" }
  var viewer: String { self == .legacy ? "wuhu_viewer" : "__Host-wuhu_viewer" }
}

struct WebCaller {
  let group: GroupID
  let crossOrigin: Bool
  let contentOrigins: [String]
  /// The bare host's origin, where the web app runs.
  var webApp: String? = nil
  let cookies: ContentCookies
}

// Sibling group hosts are same-site, so SameSite=Lax still attaches a host's
// cookie to a script, image or stylesheet request from its neighbour. The
// cookie serves same-origin callers, the paired SPA and navigations; a caller
// that sends no Sec-Fetch-Site (the native app, the CLI) is no browser. A
// navigation into a frame is left to frame-ancestors.
private let secFetchSite = HTTPField.Name("Sec-Fetch-Site")!
private let secFetchMode = HTTPField.Name("Sec-Fetch-Mode")!

private func crossOrigin(_ request: Request, paired: Bool) -> Bool {
  guard !paired, let site = request.headers[secFetchSite] else { return false }
  if site == "same-origin" || site == "none" { return false }
  return request.headers[secFetchMode] != "navigate"
}

/// A cookie-admitted cross-origin request: refused on script routes of every
/// host and on everything a group host serves.
func guarded(_ admitted: ContentAdmission, caller: WebCaller, script: Bool) -> ContentAdmission {
  guard caller.crossOrigin, script || caller.group != .shared, case .admitted(.some) = admitted else { return admitted }
  return .refused(crossOriginRefusal())
}

func crossOriginRefusal() -> Response {
  errorResponse(
    .forbidden, code: "crossOrigin",
    message: "the read session answers same-origin requests only",
  )
}

private func routedWebResponse(
  space: Space,
  caller: WebCaller,
  now: Date,
  dev: Bool,
  publicRead: Bool,
  views: ViewProviders?,
  shell: ShellSDK?,
  pageFetch: PageFetchHandler?,
  request: Request,
) async throws -> Response {
  if request.url.path == "/_/space/fetch" {
    return await pageFetchResponse(space: space, caller: caller, proxy: pageFetch, request: request)
  }
  if request.url.path == "/_/session" {
    switch request.method {
    case .options:
      return Response(status: .noContent)
    case .post:
      return try await mintReadSession(space: space, group: caller.group, dev: dev, now: now, cookies: caller.cookies, request: request)
    case .delete:
      if caller.crossOrigin { return crossOriginRefusal() }
      return try await endReadSession(space: space, cookies: caller.cookies, request: request)
    default:
      return plainStatus(.methodNotAllowed)
    }
  }
  let pageWrite = request.method == .post && pageWriteRoutes.contains(request.url.path)
  guard request.method == .get || request.method == .head || pageWrite else {
    return plainStatus(.methodNotAllowed)
  }
  let headOnly = request.method == .head
  guard let rawPath = URLComponents(url: request.url, resolvingAgainstBaseURL: false)?.percentEncodedPath else {
    return plainStatus(.badRequest)
  }
  var segments: [String] = []
  for raw in rawPath.split(separator: "/", omittingEmptySubsequences: true) {
    guard let decoded = String(raw).removingPercentEncoding else { return plainStatus(.badRequest) }
    // A decoded slash (%2F) must not smuggle extra path structure past the
    // segment split.
    guard !decoded.contains("/") else { return plainStatus(.notFound) }
    segments.append(decoded)
  }

  if segments.first == "_", !systemFolders.contains(segments.dropFirst().first ?? "") {
    let rest = segments.dropFirst()
    let response: Response
    if rest.first == "views" {
      response = providerResponse(views, shell: shell, group: caller.group, file: rest.dropFirst().joined(separator: "/"), request: request)
    } else {
      response = try await underscoreResponse(
        space: space,
        caller: caller,
        dev: dev,
        publicRead: publicRead,
        shell: shell,
        route: rest.joined(separator: "/"),
        request: request,
      )
    }
    return headOnly ? Response(status: response.status, headers: response.headers) : response
  }

  let viewer: AccountID?
  let admitted = try await admission(space: space, group: caller.group, dev: dev, publicRead: publicRead, cookies: caller.cookies, request: request)
  switch guarded(admitted, caller: caller, script: false) {
  case let .refused(wall):
    if let opened = openedInWebApp(request, caller: caller) { return opened }
    return headOnly ? Response(status: wall.status, headers: wall.headers) : wall
  case let .admitted(account):
    viewer = account
  }
  let path = "/" + segments.joined(separator: "/")
  guard (try? SpacePath(validating: path)) != nil else { return plainStatus(.notFound) }
  let trailingSlash = rawPath.count > 1 && rawPath.hasSuffix("/")
  let attachment = attachmentConversation(path) != nil
  let download = queryValues(of: request.url)["download"] == "1"
  var response = await contentResponse(
    space: space,
    group: caller.group,
    files: try await attachmentHome(path, host: caller.group, viewer: viewer, space: space),
    shell: attachment || download ? nil : shell,
    path: path,
    trailingSlash: trailingSlash,
    indexes: !attachment,
    headOnly: headOnly,
    range: request.headers[.range],
    ifNoneMatch: request.headers[.ifNoneMatch],
    ifRange: request.headers[.ifRange],
  ).viewed(by: viewer)
  if attachment { response.headers[contentSecurityPolicy] = attachmentSandbox }
  if download || (attachment && isActiveAttachment(path)), let name = segments.last {
    response.headers[contentDisposition] = "attachment; filename*=UTF-8''" + extValue(name)
  }
  return response
}

// A share link is `https://<host>/<path>?group=<g>`, the web app's own URL;
// a link written before that named `https://<g>.<host>/<path>`. Opened in a
// tab with no read session, the group host sends it to the web app, which
// signs in and shows the document; a frame, a fetch, or a navigation the
// cookie admits gets the content.
private let secFetchDest = HTTPField.Name("Sec-Fetch-Dest")!

private func openedInWebApp(_ request: Request, caller: WebCaller) -> Response? {
  guard request.method == .get, request.headers[secFetchDest] == "document", request.headers[secFetchMode] == "navigate",
        let webApp = caller.webApp,
        let components = URLComponents(url: request.url, resolvingAgainstBaseURL: false)
  else { return nil }
  var items = components.percentEncodedQuery.map { $0.split(separator: "&").map(String.init) } ?? []
  items.removeAll { $0.hasPrefix("group=") }
  if caller.group != .shared { items.append("group=" + caller.group.rawValue) }
  var headers = Headers()
  headers[.location] = webApp + components.percentEncodedPath + (items.isEmpty ? "" : "?" + items.joined(separator: "&"))
  headers[.cacheControl] = "no-store"
  return Response(status: .seeOther, headers: headers)
}

private let contentDisposition = HTTPField.Name("Content-Disposition")!

/// RFC 8187 `ext-value` bytes: attr-char stays, every other UTF-8 byte is `%XX`.
private func extValue(_ name: String) -> String {
  var encoded = ""
  for byte in name.utf8 {
    if attrChars.contains(byte) {
      encoded.unicodeScalars.append(Unicode.Scalar(byte))
    } else {
      encoded += (byte < 0x10 ? "%0" : "%") + String(byte, radix: 16, uppercase: true)
    }
  }
  return encoded
}

private let attrChars = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789!#$&+-.^_`|~".utf8)

private let systemFolders: Set<String> = ["sessions", "machines", "conversations"]
private let pageWriteRoutes: Set<String> = ["/_/space/rows", "/_/space/attributes"]

/// A conversation's attachment folder is served on the host of the group the
/// viewer acts in, whichever group homes the conversation: the SPA opens
/// `/_/conversations/<id>/attachments/…` on its own content origin, the
/// hostless path with any `wuhu://<group>.localspace` prefix dropped, and the
/// conversation id names the group whose files answer. That group serves it
/// when the host's group reads it or the viewer is a member of the
/// conversation (a cross-group DM); anything else stays the host's own path.
private func attachmentHome(_ path: String, host: GroupID, viewer: AccountID?, space: Space) async throws -> GroupID? {
  guard let id = attachmentConversation(path),
        let conversation = try? await space.sessions.conversation(id),
        conversation.group != host
  else { return nil }
  if try await space.reads(host).contains(conversation.group) { return conversation.group }
  guard let member = try await webPrincipal(viewer, group: host, space: space).member,
        try await space.sessions.readsAttachment(path, in: conversation.group, member: member)
  else { return nil }
  return conversation.group
}

/// The conversation whose attachment folder `path` is in, if it is in one.
private func attachmentConversation(_ path: String) -> ConversationID? {
  let parts = path.split(separator: "/", omittingEmptySubsequences: true)
  guard parts.count >= 4, parts[0] == "_", parts[1] == "conversations", parts[3] == "attachments" else { return nil }
  return ConversationID(String(parts[2]))
}

private let attachmentSandbox = "sandbox allow-scripts"
private let activeAttachmentExtensions: Set<String> = ["html", "htm", "xhtml", "xht", "svg", "xml"]

private func isActiveAttachment(_ path: String) -> Bool {
  guard let name = path.split(separator: "/").last, let dot = name.lastIndex(of: "."), dot != name.startIndex else { return false }
  return activeAttachmentExtensions.contains(name[name.index(after: dot)...].lowercased())
}

// The content-origin wall. Space content — files, /_/query, /_/observe — is
// admitted by a live read-session cookie minted on this host, for a member of
// the host's group; product chrome (shell.js, bundled views, the /_/session
// minter itself) stays open so a browser can reach the point of
// authenticating. --public-read opens `shared.<host>` reads on purpose; it never
// opens another group host or the API. An admitted cookie names its account in
// Wuhu-Viewer, which the page service worker files what it keeps under.
enum ContentAdmission {
  case admitted(AccountID?)
  case refused(Response)
}

func admission(space: Space, group: GroupID, dev: Bool, publicRead: Bool, cookies: ContentCookies, request: Request) async throws -> ContentAdmission {
  if dev || (publicRead && group == .shared) { return .admitted(nil) }
  return try await cookieAdmission(space: space, group: group, cookies: cookies, request: request)
}

/// A live read session minted on this host, for a member of its group.
func cookieAdmission(space: Space, group: GroupID, cookies: ContentCookies, request: Request) async throws -> ContentAdmission {
  // Every wuhu_read the browser sent is tried: a sibling host may toss its
  // own cookie at the parent domain, and it must not shadow this host's.
  for raw in readCookieTokens(request: request, cookies: cookies) {
    guard let account = try await space.account(readSession: ReadSessionToken(rawValue: raw), in: group) else { continue }
    let member = group == .shared ? true : try await space.isMember(account, of: group)
    guard member else {
      return .refused(errorResponse(
        .forbidden, code: "groupForbidden", message: "you are not a member of group \(group.rawValue)",
      ))
    }
    return .admitted(account)
  }
  return .refused(errorResponse(
    .unauthorized,
    code: "unauthorized",
    message: "content reads require a live read session",
    hint: group == .shared
      ? "open this space in the web app to establish one, or run the server with --public-read"
      : "open this group in the web app to establish one",
  ))
}

private let wuhuViewer = HTTPField.Name("Wuhu-Viewer")!

extension Response {
  func viewed(by viewer: AccountID?) -> Response {
    var response = self
    response.headers[wuhuViewer] = viewer?.rawValue
    return response
  }
}

// The read cookie's lifetime is server-chosen, never the bearer's own `exp`:
// a browser could otherwise mint a decades-long content credential that
// outlives key revocation, and an honest 300s assertion would kill the cookie
// mid-browse. The SPA re-mints on each page load, so this only has to outlast
// one browsing session.
private let readSessionTTL: TimeInterval = 12 * 3600

// The page service worker reads its cache as the account wuhu_viewer names:
// not a credential, only which account's entries this browser may paint, so
// it is readable by script and outlives the read cookie, letting a reopen
// with the space unreachable paint what that account kept. A mint for
// another account replaces it, and ending the session clears it.
private let viewerCookieTTL: TimeInterval = 400 * 24 * 3600

// The cookie carries no Domain: it is host-only, so a group host's session
// never reaches the bare host or a sibling group.
private func mintReadSession(space: Space, group: GroupID, dev: Bool, now: Date, cookies: ContentCookies, request: Request) async throws -> Response {
  if dev, request.headers[.authorization] == nil {
    return Response(status: .noContent)
  }
  switch try await bearerVerdict(request: request, space: space, now: now) {
  case let .verified(credential):
    if group != .shared, try await !space.isMember(credential.key.account, of: group) {
      return errorResponse(.forbidden, code: "groupForbidden", message: "you are not a member of group \(group.rawValue)")
    }
    let supersedes = readCookieTokens(request: request, cookies: cookies).first.map(ReadSessionToken.init(rawValue:))
    let token = try await space.createReadSession(
      account: credential.key.account,
      group: group,
      expiresAt: now.addingTimeInterval(readSessionTTL),
      supersedes: supersedes,
    )
    var headers = Headers()
    headers.append(HTTPField(
      name: .setCookie,
      value: "\(cookies.read)=\(token.rawValue); Path=/; HttpOnly; Secure; SameSite=Lax; Max-Age=\(Int(readSessionTTL))",
    ))
    headers.append(HTTPField(
      name: .setCookie,
      value: "\(cookies.viewer)=\(credential.key.account.rawValue); Path=/; Secure; SameSite=Lax; Max-Age=\(Int(viewerCookieTTL))",
    ))
    return Response(status: .noContent, headers: headers)
  case let .rejected(response):
    return response
  case .anonymous:
    return errorResponse(.unauthorized, code: "unauthorized", message: "a bearer assertion is required")
  }
}

// Ending a read session authenticates by the cookie it deletes; absent or
// unknown cookies still succeed so logout is idempotent.
private func endReadSession(space: Space, cookies: ContentCookies, request: Request) async throws -> Response {
  for token in readCookieTokens(request: request, cookies: cookies) {
    try await space.deleteReadSession(ReadSessionToken(rawValue: token))
  }
  var headers = Headers()
  headers.append(HTTPField(name: .setCookie, value: "\(cookies.read)=; Path=/; HttpOnly; Secure; SameSite=Lax; Max-Age=0"))
  headers.append(HTTPField(name: .setCookie, value: "\(cookies.viewer)=; Path=/; Secure; SameSite=Lax; Max-Age=0"))
  return Response(status: .noContent, headers: headers)
}

private func readCookieTokens(request: Request, cookies: ContentCookies) -> [String] {
  var tokens: [String] = []
  for pair in (request.headers[.cookie] ?? "").split(separator: ";") {
    let trimmed = pair.trimmingCharacters(in: .whitespaces)
    let prefix = cookies.read + "="
    if trimmed.hasPrefix(prefix) { tokens.append(String(trimmed.dropFirst(prefix.count))) }
  }
  return tokens
}

private func underscoreResponse(
  space: Space,
  caller: WebCaller,
  dev: Bool,
  publicRead: Bool,
  shell: ShellSDK?,
  route: String,
  request: Request,
) async throws -> Response {
  if let script = shell?.scripts[route] {
    var response = resourceResponse(name: route, data: script, cacheControl: "no-cache")
    if route == "worker.js" { response.headers[serviceWorkerAllowed] = "/" }
    return response
  }
  if route.hasPrefix("space/") {
    return try await spaceDataResponse(
      space: space, caller: caller, dev: dev, publicRead: publicRead, route: String(route.dropFirst("space/".count)),
      request: request,
    )
  }
  switch route {
  case "query":
    let viewer: AccountID?
    switch try await scriptAdmission(space: space, caller: caller, dev: dev, publicRead: publicRead, request: request) {
    case let .refused(wall): return wall
    case let .admitted(account): viewer = account
    }
    guard let sql = queryValues(of: request.url)["sql"] else {
      return errorResponse(.badRequest, code: "invalidArgument", message: "query takes ?sql=")
    }
    let context = SpaceToolContext(space: space, principal: try await webPrincipal(viewer, group: caller.group, space: space))
    let tool = SpaceToolbox.all.first { $0.name == "query" }!
    do {
      let output = try await tool.run(context, input: .object(["sql": .string(sql)]))
      return revalidatedJSON(output, ifNoneMatch: request.headers[.ifNoneMatch]).viewed(by: viewer)
    } catch {
      switch error {
      case .undecodableInput:
        return jsonResponse(error.payload, status: .badRequest)
      case .failed:
        return jsonResponse(error.payload, status: .unprocessableContent)
      }
    }
  case "observe":
    switch try await scriptAdmission(space: space, caller: caller, dev: dev, publicRead: publicRead, request: request) {
    case let .refused(wall): return wall
    case let .admitted(viewer):
      let principal = try await webPrincipal(viewer, group: caller.group, space: space)
      return await observeResponse(space: space, url: request.url, principal: principal).viewed(by: viewer)
    }
  default:
    return plainStatus(.notFound)
  }
}

/// The wall for /_/query and /_/observe: a page may be opened from anywhere,
/// but only its own origin and the paired SPA may script its reads.
func scriptAdmission(space: Space, caller: WebCaller, dev: Bool, publicRead: Bool, request: Request) async throws -> ContentAdmission {
  try await guarded(
    admission(space: space, group: caller.group, dev: dev, publicRead: publicRead, cookies: caller.cookies, request: request),
    caller: caller,
    script: true,
  )
}

private let serviceWorkerAllowed = HTTPField.Name("Service-Worker-Allowed")!

/// A query result has no single revision, so its tag is a digest of the result itself.
func revalidatedJSON(_ value: JSONValue, ifNoneMatch: String?) -> Response {
  let data = Data(value.jsonString().utf8)
  let digest = SHA256.hash(data: data).prefix(16).map { byte in
    (byte < 16 ? "0" : "") + String(byte, radix: 16)
  }
  let tag = "\"" + digest.joined() + "\""
  var headers = Headers()
  headers[.eTag] = tag
  headers[.cacheControl] = "private, no-cache"
  if let ifNoneMatch, matches(ifNoneMatch, tag) { return Response(status: .notModified, headers: headers) }
  headers[.contentType] = "application/json"
  headers[.contentLength] = String(data.count)
  return Response(status: .ok, headers: headers, body: .bytes(data, contentType: "application/json"))
}

private let drawnFlatByTheListProvider = ["wall": "list", "map": "list"]

private func providerResponse(_ views: ViewProviders?, shell: ShellSDK?, group: GroupID, file: String, request: Request) -> Response {
  if let target = URLComponents(url: request.url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "path" })?.value {
    guard let resolved = URL(string: target, relativeTo: request.url)?.absoluteURL.standardized else {
      return errorResponse(.badRequest, code: "invalidViewPath", message: "The view target is not a valid URL.")
    }
    if attachmentConversation(resolved.path) != nil {
      return errorResponse(.forbidden, code: "attachmentViewForbidden", message: "Conversation attachments cannot be view definitions.", hint: "Copy the definition to a space path outside the attachments folder.")
    }
  }
  guard let views, !file.isEmpty else { return plainStatus(.notFound) }
  let asset = drawnFlatByTheListProvider[file] ?? file
  guard let (name, data) = views.files[asset].map({ (asset, $0) }) ?? views.files[asset + ".html"].map({ (asset + ".html", $0) }) else {
    return plainStatus(.notFound)
  }
  return resourceResponse(
    name: name,
    data: injected(data, contentType: mimeType(for: name), shell: shell, group: group),
    cacheControl: "no-cache",
  )
}

private func contentResponse(
  space: Space,
  group: GroupID,
  files: GroupID? = nil,
  shell: ShellSDK?,
  path: String,
  trailingSlash: Bool,
  indexes: Bool,
  headOnly: Bool,
  range: String?,
  ifNoneMatch: String?,
  ifRange: String?,
) async -> Response {
  // The host's group decides the shell; `files` names another group whose
  // files answer, an attachment folder a viewer reads there.
  let fs = await space.fs(files ?? group)

  func served(_ data: Data, contentType: String, token: VersionToken? = nil) -> Response {
    let bytes = injected(data, contentType: contentType, shell: shell, group: group)
    var headers = Headers()
    headers[.contentType] = contentType
    headers[.acceptRanges] = "bytes"
    headers[.cacheControl] = "no-cache"
    var tag: String?
    if let token {
      let current = entityTag(token, bootstrap: bytes.count != data.count ? bootstrapVersion(group) : nil)
      tag = current
      headers[.eTag] = current
      if let ifNoneMatch, matches(ifNoneMatch, current) { return Response(status: .notModified, headers: headers) }
    }
    // A range is only honoured against the representation the client holds:
    // an If-Range that is not this strong tag (a date included) gets the
    // whole body.
    let honouredRange = ifRange == nil || ifRange?.trimmingCharacters(in: .whitespaces) == tag ? range : nil
    let status: Status
    let body: Data
    switch ByteRange(header: honouredRange, length: bytes.count) {
    case .whole:
      status = .ok
      body = bytes
    case let .partial(slice):
      status = .partialContent
      body = bytes.subdata(in: bytes.startIndex + slice.lowerBound ..< bytes.startIndex + slice.upperBound + 1)
      headers[.contentRange] = "bytes \(slice.lowerBound)-\(slice.upperBound)/\(bytes.count)"
    case .unsatisfiable:
      headers[.contentRange] = "bytes */\(bytes.count)"
      headers[.contentLength] = "0"
      return Response(status: .rangeNotSatisfiable, headers: headers)
    }
    headers[.contentLength] = String(body.count)
    if headOnly { return Response(status: status, headers: headers) }
    return Response(status: status, headers: headers, body: .bytes(body, contentType: contentType))
  }

  func file(_ candidate: String) async -> Response? {
    guard let (token, data) = try? await fs.read(candidate) else { return nil }
    return served(data, contentType: mimeType(for: candidate), token: token)
  }

  func index(_ directory: String) async -> Response {
    let prefix = directory == "/" ? "/" : directory + "/"
    if let response = await file(prefix + "index.html") { return response }
    if let response = await file(prefix + "index.md") { return response }
    guard let (_, entries) = try? await fs.list(directory) else { return plainStatus(.notFound) }
    return served(directoryListing(path: directory, entries: entries), contentType: mimeType(for: "index.html"))
  }

  if path == "/" { return await index("/") }
  guard let entry = try? await fs.stat(path) else { return plainStatus(.notFound) }
  switch entry.kind {
  case .file:
    if trailingSlash { return plainStatus(.notFound) }
    return await file(path) ?? plainStatus(.notFound)
  case .directory:
    return indexes ? await index(path) : plainStatus(.notFound)
  case .table, .symlink:
    return plainStatus(.notFound)
  }
}

/// The injections change the bytes without changing the file, so the tag
/// carries their version too: a new import map or shell reaches a cached page.
private func entityTag(_ token: VersionToken, bootstrap: String?) -> String {
  "\"\(String(decoding: token.bytes, as: UTF8.self))\(bootstrap.map { "-shell-" + $0 } ?? "")\""
}

private func bootstrapVersion(_ group: GroupID) -> String {
  SHA256.hash(data: importMapInjection + groupShellInjection(group)).prefix(6).map { byte in
    (byte < 16 ? "0" : "") + String(byte, radix: 16)
  }.joined()
}

private func matches(_ ifNoneMatch: String, _ tag: String) -> Bool {
  ifNoneMatch.split(separator: ",").contains { candidate in
    let trimmed = candidate.trimmingCharacters(in: .whitespaces)
    return trimmed == "*" || trimmed == tag || trimmed == "W/" + tag
  }
}

private let shellInjection = Data(#"<script type="module" src="/_/shell.js"></script>"#.utf8)

/// A group host tells shell.js its group in a meta ahead of the script;
/// `shared.`'s bytes are unchanged.
private func groupShellInjection(_ group: GroupID) -> Data {
  guard group != .shared else { return shellInjection }
  return Data(#"<meta name="wuhu-group" content="\#(group.rawValue)">"#.utf8) + shellInjection
}

/// `wuhu:space` resolves through an import map, which must precede every
/// module a page authors, so it opens `<head>`; shell.js closes `<body>`.
private let importMapInjection = Data(#"<script type="importmap">{"imports":{"wuhu:space":"/_/space.js"}}</script>"#.utf8)

private func injected(_ data: Data, contentType: String, shell: ShellSDK?, group: GroupID) -> Data {
  guard shell != nil, contentType.hasPrefix("text/html") else { return data }
  var served = data
  let injection = groupShellInjection(group)
  if let index = lastIndexOfBodyClose(data) {
    served.insert(contentsOf: injection, at: index)
  } else {
    served += injection
  }
  served.insert(contentsOf: importMapInjection, at: headStart(served))
  return served
}

/// Just past the `<head>` tag; without one, past the doctype; else the start.
private func headStart(_ data: Data) -> Data.Index {
  let bytes = [UInt8](data)
  func tagEnd(_ name: String) -> Int? {
    let needle = Array(name.utf8)
    var start = 0
    while start + needle.count <= bytes.count {
      var matched = true
      for (offset, expected) in needle.enumerated() {
        let byte = bytes[start + offset]
        if (expected.isASCIILetter ? byte | 0x20 : byte) != expected {
          matched = false
          break
        }
      }
      let next = start + needle.count
      if matched, next < bytes.count, [UInt8(ascii: ">"), UInt8(ascii: " "), 0x09, 0x0A, 0x0C, 0x0D, UInt8(ascii: "/")].contains(bytes[next]) {
        guard let close = bytes[next...].firstIndex(of: UInt8(ascii: ">")) else { return nil }
        return close + 1
      }
      start += 1
    }
    return nil
  }
  let offset = tagEnd("<head") ?? tagEnd("<!doctype") ?? 0
  return data.index(data.startIndex, offsetBy: offset)
}

private func lastIndexOfBodyClose(_ data: Data) -> Data.Index? {
  let needle = Array("</body>".utf8)
  guard data.count >= needle.count else { return nil }
  func matches(_ start: Data.Index) -> Bool {
    for (offset, expected) in needle.enumerated() {
      let byte = data[data.index(start, offsetBy: offset)]
      let lowered = expected.isASCIILetter ? byte | 0x20 : byte
      if lowered != expected { return false }
    }
    return true
  }
  var start = data.index(data.endIndex, offsetBy: -needle.count)
  while true {
    if matches(start) { return start }
    if start == data.startIndex { return nil }
    start = data.index(before: start)
  }
}

extension UInt8 {
  fileprivate var isASCIILetter: Bool {
    (self | 0x20) >= UInt8(ascii: "a") && (self | 0x20) <= UInt8(ascii: "z")
  }
}

private func resourceResponse(name: String, data: Data, cacheControl: String) -> Response {
  let contentType = mimeType(for: name)
  var headers = Headers()
  headers[.contentType] = contentType
  headers[.contentLength] = String(data.count)
  headers[.cacheControl] = cacheControl
  return Response(status: .ok, headers: headers, body: .bytes(data, contentType: contentType))
}

func mimeType(for path: String) -> String {
  let type = MediaType.of(path: path)
  return type.hasPrefix("text/") ? type + "; charset=utf-8" : type
}
