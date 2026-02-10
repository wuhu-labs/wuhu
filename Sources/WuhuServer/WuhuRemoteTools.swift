import Foundation
import PiAgent
import PiAI
import WuhuCore

enum WuhuRemoteTools {
  static func makeTools(
    sessionID: String,
    runnerName: String,
    runnerRegistry: RunnerRegistry,
  ) -> [AnyAgentTool] {
    let baseTools = WuhuTools.codingAgentTools(cwd: "/")
    return baseTools.map { base in
      AnyAgentTool(tool: base.tool, label: base.label) { toolCallId, args in
        guard let runner = await runnerRegistry.get(runnerName: runnerName) else {
          throw PiAIError.unsupported("Runner '\(runnerName)' is disconnected")
        }
        return try await runner.executeTool(
          sessionID: sessionID,
          toolCallId: toolCallId,
          toolName: base.tool.name,
          args: args,
        )
      }
    }
  }
}
