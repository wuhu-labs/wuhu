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

extension Scripts {
  public func configureDiscovery(contentHost: String? = nil, toolRosters: ToolRostersOutput? = nil) {
    discovery.withLock {
      if let contentHost { $0.contentHost = contentHost }
      if let toolRosters { $0.toolRosters = toolRosters }
    }
  }
}

struct ScriptDiscovery: Sendable {
  let execution: ScriptExecution
  let space: Space

  func install(in engine: JSEngine) {
    engine.define("__wuhu_discovery", promising: { arguments in
      return await spaceAnswer {
        let principal = try await space.principal(of: execution.session)
        let context = SpaceToolContext(space: space, principal: principal)
        let result: JSONValue
        switch arguments.first {
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
