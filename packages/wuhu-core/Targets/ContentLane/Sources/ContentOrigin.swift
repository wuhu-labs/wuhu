#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif

import Fetch
import HTTPTypes
import Serve
import struct SpaceContract.GroupID

/// What a group host's response carries for its origin: `Vary`, the CORS reflection to the
/// paired SPA, and the framing policy.
public func pairedHeaders(_ response: Response, request: Request, pairs: [OriginEndpoint], group: GroupID?) -> Response {
  var response = response
  response.headers[.vary] = request.method == .options
    ? "Origin, Access-Control-Request-Method, Access-Control-Request-Headers"
    : "Origin"
  if let origin = allowedOrigin(request: request, pairs: pairs) {
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

public let contentSecurityPolicy = HTTPField.Name("Content-Security-Policy")!

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
public func allowedOrigin(request: Request, pairs: [OriginEndpoint]) -> String? {
  guard let origin = request.headers[.origin],
        let requester = URL(string: origin).flatMap(originEndpoint),
        pairs.contains(requester)
  else { return nil }
  return origin
}

public func pairedOrigins(request: Request, contentHost: ContentHost, advertisedOrigin: String?) -> [OriginEndpoint] {
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

public struct OriginEndpoint: Equatable, Sendable {
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
public func contentOrigins(request: Request) -> [String] {
  originEndpoint(request.url).map { [$0.serialized] } ?? []
}

/// The group a web request reads, from its Host, whether its caller is a
/// cross-origin script the cookie must not serve, and the origin a page on
/// this host has.
public enum ContentCookies: Sendable {
  case legacy
  case hostOnly

  public var read: String { self == .legacy ? "wuhu_read" : "__Host-wuhu_read" }
  public var viewer: String { self == .legacy ? "wuhu_viewer" : "__Host-wuhu_viewer" }
}

public struct WebCaller: Sendable {
  public let group: GroupID
  public let crossOrigin: Bool
  public let contentOrigins: [String]
  /// The bare host's origin, where the web app runs.
  public var webApp: String? = nil
  public let cookies: ContentCookies

  public init(group: GroupID, crossOrigin: Bool, contentOrigins: [String], webApp: String? = nil, cookies: ContentCookies) {
    self.group = group
    self.crossOrigin = crossOrigin
    self.contentOrigins = contentOrigins
    self.webApp = webApp
    self.cookies = cookies
  }
}

// Sibling group hosts are same-site, so SameSite=Lax still attaches a host's
// cookie to a script, image or stylesheet request from its neighbour. The
// cookie serves same-origin callers, the paired SPA and navigations; a caller
// that sends no Sec-Fetch-Site (the native app, the CLI) is no browser. A
// navigation into a frame is left to frame-ancestors.
private let secFetchSite = HTTPField.Name("Sec-Fetch-Site")!
private let secFetchMode = HTTPField.Name("Sec-Fetch-Mode")!

public func crossOrigin(_ request: Request, paired: Bool) -> Bool {
  guard !paired, let site = request.headers[secFetchSite] else { return false }
  if site == "same-origin" || site == "none" { return false }
  return request.headers[secFetchMode] != "navigate"
}

// A share link is `https://<host>/<path>?group=<g>`, the web app's own URL;
// a link written before that named `https://<g>.<host>/<path>`. Opened in a
// tab with no read session, the group host sends it to the web app, which
// signs in and shows the document; a frame, a fetch, or a navigation the
// cookie admits gets the content.
private let secFetchDest = HTTPField.Name("Sec-Fetch-Dest")!

public func openedInWebApp(_ request: Request, caller: WebCaller) -> Response? {
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

public let contentDisposition = HTTPField.Name("Content-Disposition")!

/// RFC 8187 `ext-value` bytes: attr-char stays, every other UTF-8 byte is `%XX`.
public func extValue(_ name: String) -> String {
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
