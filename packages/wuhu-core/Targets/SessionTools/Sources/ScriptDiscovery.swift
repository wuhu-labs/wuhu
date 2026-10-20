#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import JSONValue
import QuickJSKit
import SpaceClient
import SpaceTools

// `wuhu:space`'s identity(), context(), groups() and the session tool roster:
// the server's own discovery routes, read as the session.
struct ScriptDiscovery: Sendable {
  let client: SpaceClient

  func install(in engine: JSEngine) {
    engine.define("__wuhu_identity_origin") { arguments in
      guard case let .string(raw)? = arguments.first,
            var parts = URLComponents(string: raw),
            let scheme = parts.scheme?.lowercased(), ["https", "http"].contains(scheme),
            let host = parts.host?.lowercased(), !host.isEmpty, !host.contains("*"),
            parts.user == nil, parts.password == nil, parts.path.isEmpty || parts.path == "/",
            parts.query == nil, parts.fragment == nil,
            parts.port == nil || (1 ... 65535).contains(parts.port!)
      else { return .null }
      parts.scheme = scheme
      parts.host = host
      parts.path = ""
      if (scheme == "https" && parts.port == 443) || (scheme == "http" && parts.port == 80) { parts.port = nil }
      return parts.string.map(JSONValue.string) ?? .null
    }
    engine.define("__wuhu_discovery", promising: { arguments in
      await spaceAnswer {
        let path = switch arguments.first {
        case .string("identity"): "/v1/identity"
        case .string("context"): "/v1/context"
        case .string("groups"): "/v1/groups"
        case .string("toolRoster"): "/v1/session-tools"
        default: throw ToolRunError.failed(code: .invalidArgument, message: "Unknown discovery operation.", hint: nil)
        }
        return try await client.api(.get, path)
      }
    })
  }
}
