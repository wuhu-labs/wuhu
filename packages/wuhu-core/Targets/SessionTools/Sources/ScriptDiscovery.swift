import protocol MainHub.Main
import enum MainHub.ScriptDiscoveryOperation
import func MainHub.spaceAnswer
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

struct ScriptDiscovery: Sendable {
  let execution: ScriptExecution
  let owner: any Main

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
        let operation: ScriptDiscoveryOperation
        switch arguments.first {
        case .string("identity"): operation = .identity
        case .string("context"): operation = .context
        case .string("groups"): operation = .groups
        case .string("toolRoster"): operation = .toolRosters
        default:
          throw ToolRunError.failed(code: .invalidArgument, message: "Unknown discovery operation.", hint: nil)
        }
        let result = try await owner.discovery(operation, session: execution.session)
        return result
      }
    })
  }
}
