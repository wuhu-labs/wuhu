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
  var identity: (@Sendable () async throws -> JSONValue)?
}

extension Scripts {
  public func configureDiscovery(contentHost: String? = nil, toolRosters: ToolRostersOutput? = nil, identity: (@Sendable () async throws -> JSONValue)? = nil) {
    discovery.withLock {
      if let contentHost { $0.contentHost = contentHost }
      if let toolRosters { $0.toolRosters = toolRosters }
      if let identity { $0.identity = identity }
    }
  }
}

struct ScriptDiscovery: Sendable {
  let execution: ScriptExecution
  let space: Space

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
        let principal = try await space.principal(of: execution.session)
        let context = SpaceToolContext(space: space, principal: principal)
        let result: JSONValue
        switch arguments.first {
        case .string("identity"):
          guard let identity = execution.tools.scripts?.discovery.withLock(\.identity) else {
            throw ToolRunError.failed(code: .unsupported, message: "The server identity is not configured on this script host.", hint: nil)
          }
          do { result = try await identity() }
          catch { throw ToolRunError.failed(code: .unsupported, message: "The server issuer is unavailable; inspect wuhu identity for configuration or directory publication errors.", hint: nil) }
        case .string("context"):
          result = try await context.discoveryContext(contentHost: execution.tools.scripts?.discovery.withLock(\.contentHost))
        case .string("groups"):
          result = try JSONValueEncoder().encode(try await context.discoveryGroups())
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
