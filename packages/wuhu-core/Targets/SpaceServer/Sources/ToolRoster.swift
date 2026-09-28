import Fetch
import LoopCore
import Serve
import ServeRouting
import SessionTools
import enum SpaceContract.SessionToolExecutor
import struct SpaceContract.ToolDescriptor
import struct SpaceContract.ToolRosterDescriptor
import struct SpaceContract.ToolRostersOutput
import enum WuhuAI.Tool

// The one declaration of who gets which tools. Kernel sessions also get the
// transcript-mutating tools the loop executes itself; Claude Code compacts on
// its own, so those are not offered over MCP.
extension SessionToolExecutor {
  public var tools: [Tool] {
    switch self {
    case .kernel: ToolExecutor.tools + KernelToolset.tools
    case .claudeCode: ToolExecutor.tools
    }
  }
}

func addToolRosterRoutes(_ router: inout Router) {
  router.get("/v1/session-tools") { request, _ in
    let requested = queryValues(of: request.url)["executor"]
    let rosters: [SessionToolExecutor]
    switch requested {
    case .none: rosters = SessionToolExecutor.allCases
    case let .some(raw):
      guard let executor = SessionToolExecutor(rawValue: raw) else {
        return errorResponse(
          .badRequest,
          code: "invalidArgument",
          message: "executor is one of: \(SessionToolExecutor.allCases.map(\.rawValue).joined(separator: ", "))",
        )
      }
      rosters = [executor]
    }
    let output = ToolRostersOutput(rosters: rosters.map { executor in
      ToolRosterDescriptor(
        executor: executor,
        tools: executor.tools.map {
          guard case let .function(name, description, parameters) = $0 else {
            preconditionFailure("session rosters cannot expose provider-hosted tools")
          }
          return ToolDescriptor(name: name, description: description, parameters: parameters)
        },
      )
    })
    return try Response.json(output)
  }
}
