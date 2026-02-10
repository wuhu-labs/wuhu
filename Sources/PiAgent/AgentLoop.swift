import Foundation
import PiAI

public typealias StreamFn = @Sendable (Model, Context, RequestOptions) async throws
  -> AsyncThrowingStream<AssistantMessageEvent, any Error>

public struct AgentContext: Sendable {
  public var systemPrompt: String
  public var messages: [Message]
  public var tools: [AnyAgentTool]

  public init(systemPrompt: String, messages: [Message], tools: [AnyAgentTool] = []) {
    self.systemPrompt = systemPrompt
    self.messages = messages
    self.tools = tools
  }
}

public struct AgentLoopConfig: Sendable {
  public var model: Model
  public var requestOptions: RequestOptions

  /// Safety valve for tests and defensive callers: stop after this many assistant turns.
  ///
  /// `nil` means unlimited.
  public var maxTurns: Int?

  public var transformContext: (@Sendable ([Message]) async throws -> [Message])?
  public var getSteeringMessages: (@Sendable () async throws -> [Message])?
  public var getFollowUpMessages: (@Sendable () async throws -> [Message])?

  public var streamFn: StreamFn

  public init(
    model: Model,
    requestOptions: RequestOptions = .init(),
    maxTurns: Int? = nil,
    transformContext: (@Sendable ([Message]) async throws -> [Message])? = nil,
    getSteeringMessages: (@Sendable () async throws -> [Message])? = nil,
    getFollowUpMessages: (@Sendable () async throws -> [Message])? = nil,
    streamFn: @escaping StreamFn = PiAI.streamSimple,
  ) {
    self.model = model
    self.requestOptions = requestOptions
    self.maxTurns = maxTurns
    self.transformContext = transformContext
    self.getSteeringMessages = getSteeringMessages
    self.getFollowUpMessages = getFollowUpMessages
    self.streamFn = streamFn
  }
}

public func agentLoop(
  prompts: [Message],
  context: AgentContext,
  config: AgentLoopConfig,
) -> AsyncThrowingStream<AgentEvent, any Error> {
  makeAgentEventStream(prompts: prompts, context: context, config: config, mode: .start)
}

public enum AgentLoopContinueError: Error, Sendable, CustomStringConvertible {
  case noMessages
  case lastMessageIsAssistant

  public var description: String {
    switch self {
    case .noMessages:
      "Cannot continue: no messages in context"
    case .lastMessageIsAssistant:
      "Cannot continue from message role: assistant"
    }
  }
}

public func agentLoopContinue(
  context: AgentContext,
  config: AgentLoopConfig,
) throws -> AsyncThrowingStream<AgentEvent, any Error> {
  guard !context.messages.isEmpty else { throw AgentLoopContinueError.noMessages }
  if case .assistant = context.messages.last { throw AgentLoopContinueError.lastMessageIsAssistant }
  return makeAgentEventStream(prompts: [], context: context, config: config, mode: .continue)
}

enum AgentLoopMode {
  case start
  case `continue`
}

private func makeAgentEventStream(
  prompts: [Message],
  context: AgentContext,
  config: AgentLoopConfig,
  mode: AgentLoopMode,
) -> AsyncThrowingStream<AgentEvent, any Error> {
  AsyncThrowingStream(AgentEvent.self, bufferingPolicy: .bufferingNewest(1024)) { continuation in
    let task = Task {
      do {
        try await runLoop(
          prompts: prompts,
          context: context,
          config: config,
          mode: mode,
          emit: { continuation.yield($0) },
        )
      } catch {
        continuation.finish(throwing: error)
        return
      }
      continuation.finish()
    }

    continuation.onTermination = { _ in
      task.cancel()
    }
  }
}

private func runLoop(
  prompts: [Message],
  context: AgentContext,
  config: AgentLoopConfig,
  mode: AgentLoopMode,
  emit: @Sendable (AgentEvent) -> Void,
) async throws {
  var newMessages: [Message] = []
  var currentContext = context
  var firstTurn = true
  var assistantTurnCount = 0

  var pendingMessages: [Message] = try await (config.getSteeringMessages?() ?? [])

  emit(.agentStart)
  emit(.turnStart)

  if mode == .start {
    for prompt in prompts {
      emit(.messageStart(message: prompt))
      emit(.messageEnd(message: prompt))
      currentContext.messages.append(prompt)
      newMessages.append(prompt)
    }
  }

  while true {
    var hasMoreToolCalls = true
    var steeringAfterTools: [Message]? = nil

    while hasMoreToolCalls || !pendingMessages.isEmpty {
      if !firstTurn {
        emit(.turnStart)
      } else {
        firstTurn = false
      }

      if !pendingMessages.isEmpty {
        for message in pendingMessages {
          emit(.messageStart(message: message))
          emit(.messageEnd(message: message))
          currentContext.messages.append(message)
          newMessages.append(message)
        }
        pendingMessages = []
      }

      assistantTurnCount += 1
      if let maxTurns = config.maxTurns, assistantTurnCount > maxTurns {
        throw PiAIError.unsupported("Agent loop exceeded maxTurns=\(maxTurns)")
      }

      let assistant = try await streamAssistantResponse(
        context: currentContext,
        config: config,
        emit: emit,
      )

      currentContext.messages.append(.assistant(assistant))
      newMessages.append(.assistant(assistant))

      if assistant.stopReason == .error || assistant.stopReason == .aborted {
        emit(.turnEnd(assistant: assistant, toolResults: []))
        emit(.agentEnd(messages: newMessages))
        return
      }

      let toolCalls = assistant.content.compactMap { block -> ToolCall? in
        if case let .toolCall(call) = block { return call }
        return nil
      }
      hasMoreToolCalls = !toolCalls.isEmpty

      var toolResults: [ToolResultMessage] = []
      if hasMoreToolCalls {
        let toolExecution = try await executeToolCalls(
          toolCalls: toolCalls,
          tools: currentContext.tools,
          emit: emit,
          getSteeringMessages: config.getSteeringMessages,
        )

        toolResults.append(contentsOf: toolExecution.toolResults)
        steeringAfterTools = toolExecution.steeringMessages

        for result in toolResults {
          let msg: Message = .toolResult(result)
          currentContext.messages.append(msg)
          newMessages.append(msg)
        }
      }

      emit(.turnEnd(assistant: assistant, toolResults: toolResults))

      if let steeringAfterTools, !steeringAfterTools.isEmpty {
        pendingMessages = steeringAfterTools
      } else {
        pendingMessages = try await (config.getSteeringMessages?() ?? [])
      }
    }

    let followUpMessages = try await (config.getFollowUpMessages?() ?? [])
    if !followUpMessages.isEmpty {
      pendingMessages = followUpMessages
      continue
    }

    break
  }

  emit(.agentEnd(messages: newMessages))
}

private func streamAssistantResponse(
  context: AgentContext,
  config: AgentLoopConfig,
  emit: @Sendable (AgentEvent) -> Void,
) async throws -> AssistantMessage {
  var messages = context.messages
  if let transform = config.transformContext {
    messages = try await transform(messages)
  }

  let llmContext = Context(
    systemPrompt: context.systemPrompt.isEmpty ? nil : context.systemPrompt,
    messages: messages,
    tools: context.tools.map(\.tool),
  )

  let stream = try await config.streamFn(config.model, llmContext, config.requestOptions)

  var partial: AssistantMessage?
  var addedPartial = false
  var final: AssistantMessage?

  for try await event in stream {
    switch event {
    case let .start(p):
      partial = p
      addedPartial = true
      emit(.messageStart(message: .assistant(p)))

    case let .textDelta(delta: _, partial: p):
      partial = p
      emit(.messageUpdate(message: .assistant(p), assistantEvent: event))

    case let .done(message):
      if addedPartial == false {
        emit(.messageStart(message: .assistant(message)))
      }
      emit(.messageEnd(message: .assistant(message)))
      final = message
    }
  }

  if let final { return final }
  if let partial {
    emit(.messageEnd(message: .assistant(partial)))
    return partial
  }

  return AssistantMessage(provider: config.model.provider, model: config.model.id, stopReason: .error)
}

private func executeToolCalls(
  toolCalls: [ToolCall],
  tools: [AnyAgentTool],
  emit: @Sendable (AgentEvent) -> Void,
  getSteeringMessages: (@Sendable () async throws -> [Message])?,
) async throws -> (toolResults: [ToolResultMessage], steeringMessages: [Message]?) {
  var results: [ToolResultMessage] = []
  var steeringMessages: [Message]? = nil

  for (index, toolCall) in toolCalls.enumerated() {
    emit(.toolExecutionStart(toolCallId: toolCall.id, toolName: toolCall.name, args: toolCall.arguments))

    let tool = tools.first { $0.tool.name == toolCall.name }

    var result: AgentToolResult
    var isError = false

    do {
      guard let tool else { throw PiAIError.unsupported("Tool \(toolCall.name) not found") }
      result = try await tool.execute(toolCallId: toolCall.id, args: toolCall.arguments)
    } catch {
      result = AgentToolResult(content: [.text(.init(text: String(describing: error)))], details: .object([:]))
      isError = true
    }

    emit(.toolExecutionEnd(toolCallId: toolCall.id, toolName: toolCall.name, result: result, isError: isError))

    let toolResultMessage = ToolResultMessage(
      toolCallId: toolCall.id,
      toolName: toolCall.name,
      content: result.content,
      details: result.details,
      isError: isError,
    )

    results.append(toolResultMessage)
    emit(.messageStart(message: .toolResult(toolResultMessage)))
    emit(.messageEnd(message: .toolResult(toolResultMessage)))

    if let getSteeringMessages {
      let steering = try await getSteeringMessages()
      if !steering.isEmpty {
        steeringMessages = steering
        if index + 1 < toolCalls.count {
          for skipped in toolCalls[(index + 1)...] {
            let skippedResult = ToolResultMessage(
              toolCallId: skipped.id,
              toolName: skipped.name,
              content: [.text(.init(text: "Skipped due to queued user message."))],
              details: .object([:]),
              isError: true,
            )
            emit(.toolExecutionStart(toolCallId: skipped.id, toolName: skipped.name, args: skipped.arguments))
            emit(.toolExecutionEnd(
              toolCallId: skipped.id,
              toolName: skipped.name,
              result: .init(content: skippedResult.content, details: skippedResult.details),
              isError: true,
            ))
            results.append(skippedResult)
            emit(.messageStart(message: .toolResult(skippedResult)))
            emit(.messageEnd(message: .toolResult(skippedResult)))
          }
        }
        break
      }
    }
  }

  return (results, steeringMessages)
}

@_spi(Testing) public func executeToolCallsForTesting(
  toolCalls: [ToolCall],
  tools: [AnyAgentTool],
  getSteeringMessages: (@Sendable () async throws -> [Message])? = nil,
) async throws -> (toolResults: [ToolResultMessage], steeringMessages: [Message]?) {
  try await executeToolCalls(
    toolCalls: toolCalls,
    tools: tools,
    emit: { _ in },
    getSteeringMessages: getSteeringMessages,
  )
}
