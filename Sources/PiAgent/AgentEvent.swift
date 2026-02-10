import Foundation
import PiAI

public enum AgentEvent: Sendable {
  case agentStart
  case agentEnd(messages: [Message])

  case turnStart
  case turnEnd(assistant: AssistantMessage, toolResults: [ToolResultMessage])

  case messageStart(message: Message)
  case messageUpdate(message: Message, assistantEvent: AssistantMessageEvent)
  case messageEnd(message: Message)

  case toolExecutionStart(toolCallId: String, toolName: String, args: JSONValue)
  case toolExecutionUpdate(toolCallId: String, toolName: String, args: JSONValue, partialResult: JSONValue)
  case toolExecutionEnd(toolCallId: String, toolName: String, result: AgentToolResult, isError: Bool)
}
