#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif

import ContentLane
import Dependencies
import Fetch
import HTTPTypes
import JSONValue
import class MainHub.Hub
import Serve
import struct SessionDomain.ConversationID
import struct SpaceContract.GroupID
import SpaceCore
import SpaceFS
import SpaceTools

func webResponse(
  space: Space,
  group: GroupID,
  contentHost: ContentHost,
  advertisedOrigin: String?,
  now: Date,
  devPerson: ResolvedPerson?,
  publicRead: Bool,
  views: [String: Data],
  shell: [String: Data]?,
  pageFetch: PageFetchHandler? = nil,
  hub: Hub? = nil,
  request: Request,
) async throws -> Response {
  let resolved = try await space.resolveGroup(group.rawValue)
  if let resolved, resolved != group, let record = try await space.group(resolved) {
    let current = record.alias
    if let current, current != group.rawValue {
      var parts = URLComponents(url: request.url, resolvingAgainstBaseURL: false)!
      parts.host = contentHost.pattern?.template.replacingOccurrences(of: "{group}", with: current).split(separator: ":").first.map(String.init) ?? current + "." + contentHost.host
      var redirect = Response(status: .temporaryRedirect)
      redirect.headers[.cacheControl] = "no-store"
      redirect.headers[.location] = parts.string!
      return redirect
    }
  }
  let pairs = pairedOrigins(request: request, contentHost: contentHost, advertisedOrigin: advertisedOrigin)
  let paired = allowedOrigin(request: request, pairs: pairs)
  var response: Response
  if let group = resolved {
    response = try await routedWebResponse(
      space: space,
      caller: WebCaller(
        group: group, crossOrigin: crossOrigin(request, paired: paired != nil),
        contentOrigins: contentOrigins(request: request), webApp: contentHost.origin,
        cookies: contentHost.pattern == nil ? .legacy : .hostOnly,
      ),
      now: now,
      devPerson: devPerson,
      publicRead: publicRead,
      views: views,
      shell: shell,
      pageFetch: pageFetch,
      hub: hub,
      request: request,
    )
  } else {
    response = errorResponse(.notFound, code: "unknownGroup", message: "this space has no group \(group.rawValue)")
  }
  return pairedHeaders(response, request: request, pairs: pairs, group: resolved)
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
  devPerson: ResolvedPerson?,
  publicRead: Bool,
  views: [String: Data],
  shell: [String: Data]?,
  pageFetch: PageFetchHandler?,
  hub: Hub?,
  request: Request,
) async throws -> Response {
  if request.url.path == "/_/space/fetch" {
    return await pageFetchResponse(space: space, caller: caller, proxy: pageFetch, request: request)
  }
  if request.url.path == "/_/space/session" || request.url.path == "/_/space/message" {
    return try await pageSessionResponse(space: space, caller: caller, devPerson: devPerson, hub: hub, request: request)
  }
  if request.url.path == "/_/session" {
    switch request.method {
    case .options:
      return Response(status: .noContent)
    case .post:
      return try await mintReadSession(space: space, group: caller.group, devPerson: devPerson, now: now, cookies: caller.cookies, request: request)
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

  if caller.group == .shared, segments.count == 4, segments[0] == "v1", segments[1] == "user", segments[3] == "avatar" {
    switch try await cookieAdmission(space: space, group: .shared, cookies: caller.cookies, request: request) {
    case let .refused(response): return response
    case let .admitted(viewer):
      return try await userAvatarResponse(space: space, person: segments[2], request: request).viewed(by: viewer)
    }
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
        devPerson: devPerson,
        publicRead: publicRead,
        shell: shell,
        route: rest.joined(separator: "/"),
        request: request,
      )
    }
    return headOnly ? Response(status: response.status, headers: response.headers) : response
  }

  let viewer: AccountID?
  let admitted = try await admission(space: space, group: caller.group, devPerson: devPerson, publicRead: publicRead, cookies: caller.cookies, request: request)
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
  if let id = attachmentConversation(path), let conversation = try? await space.sessions.conversation(id), conversation.kind == .users {
    let principal = try await webPrincipal(viewer, group: caller.group, space: space)
    guard try await space.sessions.reads(conversation, reader: principal.member, group: caller.group) else { return plainStatus(.notFound) }
  }
  var response = await contentResponse(
    space: space,
    group: caller.group,
    principal: try await webPrincipal(viewer, group: caller.group, space: space),
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
  if attachment { response.headers[contentSecurityPolicy] = response.headers[contentSecurityPolicy] ?? attachmentSandbox }
  if download || (attachment && isActiveAttachment(path)), let name = segments.last {
    response.headers[contentDisposition] = "attachment; filename*=UTF-8''" + extValue(name)
  }
  return response
}

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
  let principal = try await webPrincipal(viewer, group: host, space: space)
  if try await space.reads(for: principal).contains(conversation.group) { return conversation.group }
  guard let member = principal.member,
        space.sessions.readsAttachment(path, in: conversation.group, member: member)
  else { return nil }
  return conversation.group
}

/// The conversation folder that contains `path`.
private func attachmentConversation(_ path: String) -> ConversationID? {
  let parts = path.split(separator: "/", omittingEmptySubsequences: true)
  guard parts.count >= 3, parts[0] == "_", parts[1] == "conversations" else { return nil }
  return ConversationID(String(parts[2]))
}

private let attachmentSandbox = "sandbox allow-scripts"
private let activeAttachmentExtensions: Set<String> = ["html", "htm", "xhtml", "xht", "svg", "xml"]

private func isActiveAttachment(_ path: String) -> Bool {
  guard let name = path.split(separator: "/").last, let dot = name.lastIndex(of: "."), dot != name.startIndex else { return false }
  return activeAttachmentExtensions.contains(name[name.index(after: dot)...].lowercased())
}

// The content-origin wall. Space content — files, /_/query, /_/observe — is
// admitted by a live read-session cookie minted on this host, for whoever may
// read the host's group; product chrome (shell.js, bundled views, the
// /_/session minter itself) stays open so a browser can reach the point of
// authenticating. --public-read opens `shared.<host>` reads on purpose; it never
// opens another group host or the API. An admitted cookie names its account in
// Wuhu-Viewer, which the page service worker files what it keeps under.
enum ContentAdmission {
  case admitted(AccountID?)
  case refused(Response)
}

func admission(space: Space, group: GroupID, devPerson: ResolvedPerson?, publicRead: Bool, cookies: ContentCookies, request: Request) async throws -> ContentAdmission {
  @Dependency(\.date) var dateGen
  if devPerson != nil, request.headers[.authorization] == nil, !readCookieTokens(request: request, cookies: cookies).isEmpty {
    return try await cookieAdmission(space: space, group: group, cookies: cookies, request: request)
  }
  if devPerson != nil {
    switch try await personVerdict(request: request, space: space, devPerson: devPerson, now: dateGen.now) {
    case let .refused(response): return .refused(response)
    case let .person(person):
      guard try await space.role(of: .person(persona: person.persona, account: person.account), in: group, acting: group) != nil else {
        return .refused(errorResponse(.forbidden, code: "groupForbidden", message: "you may not read group \(group.rawValue)"))
      }
      return .admitted(person.account)
    }
  }
  if publicRead && group == .shared { return .admitted(nil) }
  return try await cookieAdmission(space: space, group: group, cookies: cookies, request: request)
}

/// A live read session minted on this host, for whoever may read its group.
func cookieAdmission(space: Space, group: GroupID, cookies: ContentCookies, request: Request) async throws -> ContentAdmission {
  // Every wuhu_read the browser sent is tried: a sibling host may toss its
  // own cookie at the parent domain, and it must not shadow this host's.
  for raw in readCookieTokens(request: request, cookies: cookies) {
    guard let account = try await space.account(readSession: ReadSessionToken(rawValue: raw), in: group) else { continue }
    let actor = Actor.person(persona: account.rawValue, account: account)
    guard try await space.role(of: actor, in: group, acting: group) != nil else {
      return .refused(errorResponse(
        .forbidden, code: "groupForbidden", message: "you may not read group \(group.rawValue)",
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
private func mintReadSession(space: Space, group: GroupID, devPerson: ResolvedPerson?, now: Date, cookies: ContentCookies, request: Request) async throws -> Response {
  let account: AccountID
  if devPerson != nil {
    switch try await personVerdict(request: request, space: space, devPerson: devPerson, now: now) {
    case let .person(person): account = person.account
    case let .refused(response): return response
    }
  } else {
    switch try await bearerVerdict(request: request, space: space, now: now) {
    case let .verified(credential): account = credential.key.account
    case let .rejected(response): return response
    case .missing: return errorResponse(.unauthorized, code: "unauthorized", message: "a bearer assertion is required")
    }
  }
  let actor = Actor.person(persona: account.rawValue, account: account)
  if try await space.role(of: actor, in: group, acting: group) == nil {
    return errorResponse(.forbidden, code: "groupForbidden", message: "you may not read group \(group.rawValue)")
  }
  let supersedes = readCookieTokens(request: request, cookies: cookies).first.map(ReadSessionToken.init(rawValue:))
  let token = try await space.createReadSession(
    account: account,
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
    value: "\(cookies.viewer)=\(account.rawValue); Path=/; Secure; SameSite=Lax; Max-Age=\(Int(viewerCookieTTL))",
  ))
  return Response(status: .noContent, headers: headers)
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
  devPerson: ResolvedPerson?,
  publicRead: Bool,
  shell: [String: Data]?,
  route: String,
  request: Request,
) async throws -> Response {
  if let script = shell?[route] {
    var response = resourceResponse(name: route, data: script, cacheControl: "no-cache")
    if route == "worker.js" { response.headers[serviceWorkerAllowed] = "/" }
    return response
  }
  if route.hasPrefix("space/") {
    return try await spaceDataResponse(
      space: space, caller: caller, devPerson: devPerson, publicRead: publicRead, route: String(route.dropFirst("space/".count)),
      request: request,
    )
  }
  switch route {
  case "query":
    let viewer: AccountID?
    switch try await scriptAdmission(space: space, caller: caller, devPerson: devPerson, publicRead: publicRead, request: request) {
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
    switch try await scriptAdmission(space: space, caller: caller, devPerson: devPerson, publicRead: publicRead, request: request) {
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
func scriptAdmission(space: Space, caller: WebCaller, devPerson: ResolvedPerson?, publicRead: Bool, request: Request) async throws -> ContentAdmission {
  try await guarded(
    admission(space: space, group: caller.group, devPerson: devPerson, publicRead: publicRead, cookies: caller.cookies, request: request),
    caller: caller,
    script: true,
  )
}

private let serviceWorkerAllowed = HTTPField.Name("Service-Worker-Allowed")!

private func providerResponse(_ views: [String: Data], shell: [String: Data]?, group: GroupID, file: String, request: Request) -> Response {
  if let target = URLComponents(url: request.url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "path" })?.value {
    guard let resolved = URL(string: target, relativeTo: request.url)?.absoluteURL.standardized else {
      return errorResponse(.badRequest, code: "invalidViewPath", message: "The view target is not a valid URL.")
    }
    if attachmentConversation(resolved.path) != nil {
      return errorResponse(.forbidden, code: "attachmentViewForbidden", message: "Conversation attachments cannot be view definitions.", hint: "Copy the definition to a space path outside the attachments folder.")
    }
  }
  guard !file.isEmpty else { return plainStatus(.notFound) }
  guard let (name, data) = viewAsset(views, file: file) else {
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
  principal: Principal,
  files: GroupID? = nil,
  shell: [String: Data]?,
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
    ContentLane.served(
      data, contentType: contentType, version: token.map { String(decoding: $0.bytes, as: UTF8.self) }, shell: shell, group: group,
      headOnly: headOnly, range: range, ifNoneMatch: ifNoneMatch, ifRange: ifRange,
    )
  }

  func file(_ candidate: String) async -> Response? {
    guard let (token, data) = try? await fs.read(candidate) else { return nil }
    return served(data, contentType: mimeType(for: candidate), token: token)
  }

  func index(_ directory: String) async -> Response {
    let prefix = directory == "/" ? "/" : directory + "/"
    if let response = await file(prefix + "index.html") { return response }
    if let response = await file(prefix + "index.md") { return response }
    guard let (_, candidates) = try? await fs.list(directory) else { return plainStatus(.notFound) }
    var entries: [SpaceFS.Entry] = []
    for entry in candidates {
      if let conversation = space.sessions.attachmentConversation(prefix + entry.name, in: files ?? group), conversation.kind == .users {
        guard (try? await space.sessions.reads(conversation, reader: principal.member, group: principal.group)) == true else { continue }
      }
      entries.append(entry)
    }
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
