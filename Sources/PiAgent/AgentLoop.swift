import Foundation
import PiAI

private final class ProducerHolder: @unchecked Sendable {
  private let lock = Mutex<Task<[AgentMessage], Never>?>(initialState: nil)

  func set(_ task: Task<[AgentMessage], Never>) {
    lock.withLock { $0 = task }
  }

  func get() -> Task<[AgentMessage], Never>? {
    lock.withLock { $0 }
  }

  func cancel() {
    get()?.cancel()
  }
}

private final class EventSink: @unchecked Sendable {
  private let continuation: AsyncStream<AgentEvent>.Continuation

  init(_ continuation: AsyncStream<AgentEvent>.Continuation) {
    self.continuation = continuation
  }

  func yield(_ event: AgentEvent) {
    continuation.yield(event)
  }

  func finish() {
    continuation.finish()
  }
}

public func agentLoop(
  prompts: [AgentMessage],
  context: AgentContext,
  config: AgentLoopConfig,
  cancellationToken: CancellationToken? = nil,
) -> AgentEventStream {
  AgentEventStream(
    prompts: prompts,
    context: context,
    config: config,
    cancellationToken: cancellationToken,
    isContinue: false,
  )
}

public func agentLoopContinue(
  context: AgentContext,
  config: AgentLoopConfig,
  cancellationToken: CancellationToken? = nil,
) throws -> AgentEventStream {
  guard !context.messages.isEmpty else {
    throw AgentError.invalidContinue("Cannot continue: no messages in context")
  }

  if case let .llm(last) = context.messages.last, case .assistant = last {
    throw AgentError.invalidContinue("Cannot continue from message role: assistant")
  }

  return AgentEventStream(
    prompts: [],
    context: context,
    config: config,
    cancellationToken: cancellationToken,
    isContinue: true,
  )
}

public struct AgentEventStream: AsyncSequence, Sendable {
  public typealias Element = AgentEvent

  private let stream: AsyncStream<AgentEvent>
  private let resultTask: Task<[AgentMessage], Never>

  init(
    prompts: [AgentMessage],
    context: AgentContext,
    config: AgentLoopConfig,
    cancellationToken: CancellationToken?,
    isContinue: Bool,
  ) {
    let token = cancellationToken ?? CancellationToken()
    let holder = ProducerHolder()

    stream = AsyncStream { continuation in
      let sink = EventSink(continuation)
      continuation.onTermination = { _ in
        holder.cancel()
      }

      let producer = Task<[AgentMessage], Never> {
        if token.isCancelled || Task.isCancelled {
          sink.finish()
          return []
        }

        sink.yield(.agentStart)
        sink.yield(.turnStart)
        if !isContinue {
          for prompt in prompts {
            sink.yield(.messageStart(message: prompt))
            sink.yield(.messageEnd(message: prompt))
          }
        }

        var newMessages: [AgentMessage] = prompts
        var current = context
        current.messages.append(contentsOf: prompts)

        await runLoop(
          currentContext: &current,
          newMessages: &newMessages,
          config: config,
          cancellationToken: token,
          emit: { sink.yield($0) },
        )

        sink.yield(.agentEnd(messages: newMessages))
        sink.finish()
        return newMessages
      }

      holder.set(producer)
    }

    resultTask = Task {
      while true {
        if let task = holder.get() {
          return await task.value
        }
        await Task.yield()
      }
    }
  }

  public func makeAsyncIterator() -> AsyncStream<AgentEvent>.Iterator {
    stream.makeAsyncIterator()
  }

  public func result() async -> [AgentMessage] {
    await resultTask.value
  }
}

private func runLoop(
  currentContext: inout AgentContext,
  newMessages: inout [AgentMessage],
  config: AgentLoopConfig,
  cancellationToken: CancellationToken,
  emit: @escaping @Sendable (AgentEvent) -> Void,
) async {
  var firstTurn = true
  var pendingMessages: [AgentMessage] = await (try? config.getSteeringMessages?()) ?? []

  while true {
    var hasMoreToolCalls = true
    var steeringAfterTools: [AgentMessage]? = nil

    while hasMoreToolCalls || !pendingMessages.isEmpty {
      if !firstTurn {
        emit(.turnStart)
      } else {
        firstTurn = false
      }

      if cancellationToken.isCancelled { return }

      if !pendingMessages.isEmpty {
        for message in pendingMessages {
          emit(.messageStart(message: message))
          emit(.messageEnd(message: message))
          currentContext.messages.append(message)
          newMessages.append(message)
        }
        pendingMessages = []
      }

      let assistant = await streamAssistantResponse(
        context: &currentContext,
        config: config,
        cancellationToken: cancellationToken,
        emit: emit,
      )

      newMessages.append(assistant)

      let (toolCalls, toolResults, steering) = await executeToolCallsIfNeeded(
        context: &currentContext,
        assistantMessage: assistant,
        cancellationToken: cancellationToken,
        emit: emit,
        getSteeringMessages: config.getSteeringMessages,
      )

      hasMoreToolCalls = !toolCalls.isEmpty
      steeringAfterTools = steering

      for result in toolResults {
        currentContext.messages.append(.llm(.toolResult(result)))
        newMessages.append(.llm(.toolResult(result)))
      }

      emit(.turnEnd(message: assistant, toolResults: toolResults))

      if let steering = steeringAfterTools, !steering.isEmpty {
        pendingMessages = steering
        steeringAfterTools = nil
      } else {
        pendingMessages = await (try? config.getSteeringMessages?()) ?? []
      }
    }

    let followUps = await (try? config.getFollowUpMessages?()) ?? []
    if !followUps.isEmpty {
      pendingMessages = followUps
      continue
    }

    break
  }
}

private func streamAssistantResponse(
  context: inout AgentContext,
  config: AgentLoopConfig,
  cancellationToken: CancellationToken,
  emit: @escaping @Sendable (AgentEvent) -> Void,
) async -> AgentMessage {
  if cancellationToken.isCancelled {
    let message: AgentMessage = .custom(.init(role: "error", content: "Cancelled"))
    context.messages.append(message)
    emit(.messageStart(message: message))
    emit(.messageEnd(message: message))
    return message
  }

  var messages = context.messages
  if let transformContext = config.transformContext {
    if let transformed = try? await transformContext(messages, cancellationToken) {
      messages = transformed
    }
  }

  let llmMessages = await (try? config.convertToLlm(messages)) ?? []
  let tools = context.tools.map(\.tool)

  var options = config.requestOptions
  if let getApiKey = config.getApiKey, let key = try? await getApiKey(config.model.provider) {
    options.apiKey = key
  }

  let llmContext = SimpleContext(
    systemPrompt: context.systemPrompt.isEmpty ? nil : context.systemPrompt,
    messages: llmMessages,
    tools: tools.isEmpty ? nil : tools,
  )

  let stream: AsyncThrowingStream<AssistantMessageEvent, any Error>
  do {
    stream = try await config.streamFn(config.model, llmContext, options)
  } catch {
    let message: AgentMessage = .custom(.init(role: "error", content: String(describing: error)))
    context.messages.append(message)
    emit(.messageStart(message: message))
    emit(.messageEnd(message: message))
    return message
  }

  var partial: AssistantMessage?
  var addedPartial = false
  var finalMessage: AssistantMessage?

  do {
    for try await event in stream {
      if cancellationToken.isCancelled { break }

      switch event {
      case let .start(p):
        partial = p
        let msg = AgentMessage.llm(.assistant(p))
        context.messages.append(msg)
        addedPartial = true
        emit(.messageStart(message: msg))

      case let .textDelta(delta, p):
        partial = p
        if addedPartial {
          context.messages[context.messages.count - 1] = .llm(.assistant(p))
        }
        emit(.messageUpdate(message: .llm(.assistant(p)), assistantMessageEvent: .textDelta(delta: delta, partial: p)))

      case let .done(message):
        finalMessage = message
      }
    }
  } catch {
    finalMessage = AssistantMessage(provider: config.model.provider, model: config.model.id, stopReason: .error)
    finalMessage?.errorMessage = String(describing: error)
  }

  let resolved = finalMessage ?? partial ?? AssistantMessage(provider: config.model.provider, model: config.model.id)

  let finalAgentMessage = AgentMessage.llm(.assistant(resolved))
  if addedPartial {
    context.messages[context.messages.count - 1] = finalAgentMessage
  } else {
    context.messages.append(finalAgentMessage)
    emit(.messageStart(message: finalAgentMessage))
  }
  emit(.messageEnd(message: finalAgentMessage))
  return finalAgentMessage
}

private func executeToolCallsIfNeeded(
  context: inout AgentContext,
  assistantMessage: AgentMessage,
  cancellationToken: CancellationToken,
  emit: @escaping @Sendable (AgentEvent) -> Void,
  getSteeringMessages: (@Sendable () async throws -> [AgentMessage])?,
) async -> (toolCalls: [ToolCall], toolResults: [ToolResultMessage], steeringMessages: [AgentMessage]?) {
  guard case let .llm(msg) = assistantMessage, case let .assistant(assistant) = msg else {
    return ([], [], nil)
  }

  let toolCalls: [ToolCall] = assistant.content.compactMap { part in
    if case let .toolCall(call) = part { return call }
    return nil
  }

  guard !toolCalls.isEmpty else { return ([], [], nil) }

  var results: [ToolResultMessage] = []
  var steeringMessages: [AgentMessage]? = nil

  for (idx, call) in toolCalls.enumerated() {
    if cancellationToken.isCancelled { break }

    emit(.toolExecutionStart(toolCallId: call.id, toolName: call.name, args: call.arguments))

    var toolResult: AgentToolResult
    var isError = false

    do {
      guard let tool = context.tools.first(where: { $0.tool.name == call.name }) else {
        throw PiAIError.unsupported("Tool \(call.name) not found")
      }

      let validated = try validateToolArguments(tool: tool.tool, toolCall: call)
      toolResult = try await tool.execute(call.id, validated, cancellationToken) { partial in
        emit(.toolExecutionUpdate(toolCallId: call.id, toolName: call.name, args: call.arguments, partialResult: partial))
      }
    } catch {
      toolResult = .init(content: String(describing: error), details: .object([:]))
      isError = true
    }

    emit(.toolExecutionEnd(toolCallId: call.id, toolName: call.name, result: toolResult, isError: isError))

    let toolResultMessage = ToolResultMessage(
      toolCallId: call.id,
      toolName: call.name,
      content: toolResult.content,
      isError: isError,
    )

    results.append(toolResultMessage)
    emit(.messageStart(message: .llm(.toolResult(toolResultMessage))))
    emit(.messageEnd(message: .llm(.toolResult(toolResultMessage))))

    if let getSteeringMessages, let steering = try? await getSteeringMessages(), !steering.isEmpty {
      steeringMessages = steering
      let remaining = toolCalls.suffix(from: idx + 1)
      for skipped in remaining {
        let skippedResult = ToolResultMessage(
          toolCallId: skipped.id,
          toolName: skipped.name,
          content: "Skipped due to queued user message.",
          isError: true,
        )
        results.append(skippedResult)
        emit(.toolExecutionStart(toolCallId: skipped.id, toolName: skipped.name, args: skipped.arguments))
        emit(.toolExecutionEnd(
          toolCallId: skipped.id,
          toolName: skipped.name,
          result: .init(content: skippedResult.content, details: .object([:])),
          isError: true,
        ))
        emit(.messageStart(message: .llm(.toolResult(skippedResult))))
        emit(.messageEnd(message: .llm(.toolResult(skippedResult))))
      }
      break
    }
  }

  return (toolCalls, results, steeringMessages)
}
