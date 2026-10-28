#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif

/// What a request's origin reads as for an identity token: `scheme://host[:port]`,
/// lowercase, default ports dropped; nil for anything but http(s) to a plain
/// host.
public func fetchOrigin(_ url: URL) -> String? {
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
