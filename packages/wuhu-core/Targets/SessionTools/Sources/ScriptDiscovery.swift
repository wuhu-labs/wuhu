#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import JSONValue
import QuickJSKit
import SessionDomain
import struct SpaceContract.ToolRostersOutput
import SpaceCore
import SpaceTools

struct ScriptDiscoveryConfiguration: Sendable {
  var contentHost: String?
  var toolRosters: ToolRostersOutput?
}

struct ScriptDiscovery: Sendable {
  let execution: ScriptExecution
  let owner: any ScriptOwnerClient

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
      return await spaceAnswer {
        let result: JSONValue
        switch arguments.first {
        case .string("identity"):
          result = try await owner.identityConfiguration()
        case .string("context"):
          result = try await owner.discoveryContext(session: execution.session, contentHost: execution.tools.scripts?.discovery.withLock(\.contentHost))
        case .string("groups"):
          result = try await owner.discoveryGroups(session: execution.session)
        case .string("toolRoster"):
          guard let roster = execution.tools.scripts?.discovery.withLock(\.toolRosters) else {
            throw ToolRunError.failed(code: .unsupported, message: "The session roster is not configured on this script host.", hint: nil)
          }
          result = try JSONValueEncoder().encode(roster)
        default:
          throw ToolRunError.failed(code: .invalidArgument, message: "Unknown discovery operation.", hint: nil)
        }
        return result
      }
    })
  }
}
