import Foundation
import PiAI

public enum ThinkingLevel: String, Sendable {
  case off
  case minimal
  case low
  case medium
  case high
  case xhigh
}

public struct CustomAgentMessage: Sendable, Hashable {
  public var role: String
  public var content: String
  public var timestamp: Date

  public init(role: String, content: String, timestamp: Date = Date()) {
    self.role = role
    self.content = content
    self.timestamp = timestamp
  }
}

public enum AgentMessage: Sendable, Hashable {
  case llm(Message)
  case custom(CustomAgentMessage)

  public var role: String {
    switch self {
    case let .llm(m):
      switch m {
      case .user: "user"
      case .assistant: "assistant"
      case .toolResult: "toolResult"
      }
    case let .custom(m):
      m.role
    }
  }
}

public struct AgentToolResult: Sendable, Hashable {
  public var content: String
  public var details: JSONValue

  public init(content: String, details: JSONValue = .object([:])) {
    self.content = content
    self.details = details
  }
}

public typealias AgentToolUpdateCallback = @Sendable (_ partialResult: AgentToolResult) -> Void

public struct AgentTool: Sendable {
  public var tool: Tool
  public var label: String
  public var execute: @Sendable (
    _ toolCallId: String,
    _ params: JSONValue,
    _ cancellationToken: CancellationToken?,
    _ onUpdate: AgentToolUpdateCallback?,
  ) async throws -> AgentToolResult

  public init(
    tool: Tool,
    label: String,
    execute: @escaping @Sendable (
      _ toolCallId: String,
      _ params: JSONValue,
      _ cancellationToken: CancellationToken?,
      _ onUpdate: AgentToolUpdateCallback?,
    ) async throws -> AgentToolResult,
  ) {
    self.tool = tool
    self.label = label
    self.execute = execute
  }
}

public struct AgentContext: Sendable {
  public var systemPrompt: String
  public var messages: [AgentMessage]
  public var tools: [AgentTool]

  public init(systemPrompt: String, messages: [AgentMessage], tools: [AgentTool] = []) {
    self.systemPrompt = systemPrompt
    self.messages = messages
    self.tools = tools
  }
}

public typealias ConvertToLlm = @Sendable (_ messages: [AgentMessage]) async throws -> [Message]
public typealias TransformContext = @Sendable (_ messages: [AgentMessage], _ cancellationToken: CancellationToken?) async
  throws -> [AgentMessage]

public typealias StreamFn = @Sendable (_ model: Model, _ context: SimpleContext, _ options: RequestOptions) async throws
  -> AsyncThrowingStream<AssistantMessageEvent, any Error>

public struct AgentLoopConfig: Sendable {
  public var model: Model
  public var convertToLlm: ConvertToLlm
  public var transformContext: TransformContext?
  public var streamFn: StreamFn
  public var requestOptions: RequestOptions
  public var getApiKey: (@Sendable (_ provider: Provider) async throws -> String?)?
  public var getSteeringMessages: (@Sendable () async throws -> [AgentMessage])?
  public var getFollowUpMessages: (@Sendable () async throws -> [AgentMessage])?

  public init(
    model: Model,
    convertToLlm: @escaping ConvertToLlm,
    transformContext: TransformContext? = nil,
    streamFn: @escaping StreamFn = DefaultStream.stream,
    requestOptions: RequestOptions = .init(),
    getApiKey: (@Sendable (_ provider: Provider) async throws -> String?)? = nil,
    getSteeringMessages: (@Sendable () async throws -> [AgentMessage])? = nil,
    getFollowUpMessages: (@Sendable () async throws -> [AgentMessage])? = nil,
  ) {
    self.model = model
    self.convertToLlm = convertToLlm
    self.transformContext = transformContext
    self.streamFn = streamFn
    self.requestOptions = requestOptions
    self.getApiKey = getApiKey
    self.getSteeringMessages = getSteeringMessages
    self.getFollowUpMessages = getFollowUpMessages
  }
}

public enum AgentEvent: Sendable, Hashable {
  case agentStart
  case agentEnd(messages: [AgentMessage])

  case turnStart
  case turnEnd(message: AgentMessage, toolResults: [ToolResultMessage])

  case messageStart(message: AgentMessage)
  case messageUpdate(message: AgentMessage, assistantMessageEvent: AssistantMessageEvent)
  case messageEnd(message: AgentMessage)

  case toolExecutionStart(toolCallId: String, toolName: String, args: JSONValue)
  case toolExecutionUpdate(toolCallId: String, toolName: String, args: JSONValue, partialResult: AgentToolResult)
  case toolExecutionEnd(toolCallId: String, toolName: String, result: AgentToolResult, isError: Bool)
}

public struct AgentState: Sendable {
  public var systemPrompt: String
  public var model: Model
  public var thinkingLevel: ThinkingLevel
  public var tools: [AgentTool]
  public var messages: [AgentMessage]
  public var isStreaming: Bool
  public var streamMessage: AgentMessage?
  public var pendingToolCalls: Set<String>
  public var error: String?

  public init(
    systemPrompt: String = "",
    model: Model = .init(id: "gpt-4.1-mini", provider: .openai),
    thinkingLevel: ThinkingLevel = .off,
    tools: [AgentTool] = [],
    messages: [AgentMessage] = [],
    isStreaming: Bool = false,
    streamMessage: AgentMessage? = nil,
    pendingToolCalls: Set<String> = [],
    error: String? = nil,
  ) {
    self.systemPrompt = systemPrompt
    self.model = model
    self.thinkingLevel = thinkingLevel
    self.tools = tools
    self.messages = messages
    self.isStreaming = isStreaming
    self.streamMessage = streamMessage
    self.pendingToolCalls = pendingToolCalls
    self.error = error
  }
}

public final class CancellationToken: @unchecked Sendable {
  private let lock: Mutex<Bool>

  public init() {
    lock = Mutex(initialState: false)
  }

  public func cancel() {
    lock.withLock { $0 = true }
  }

  public var isCancelled: Bool {
    lock.withLock { $0 }
  }
}
