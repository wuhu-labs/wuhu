import Foundation
import PiAI

public struct AgentState: Sendable {
  public var systemPrompt: String
  public var model: Model
  public var tools: [AnyAgentTool]
  public var messages: [Message]

  public var isStreaming: Bool
  public var streamMessage: Message?
  public var pendingToolCalls: Set<String>
  public var error: String?

  public init(
    systemPrompt: String = "",
    model: Model,
    tools: [AnyAgentTool] = [],
    messages: [Message] = [],
    isStreaming: Bool = false,
    streamMessage: Message? = nil,
    pendingToolCalls: Set<String> = [],
    error: String? = nil,
  ) {
    self.systemPrompt = systemPrompt
    self.model = model
    self.tools = tools
    self.messages = messages
    self.isStreaming = isStreaming
    self.streamMessage = streamMessage
    self.pendingToolCalls = pendingToolCalls
    self.error = error
  }
}

public struct AgentOptions: Sendable {
  public var initialState: AgentState?
  public var requestOptions: RequestOptions
  public var streamFn: StreamFn
  public var maxTurns: Int?

  public init(
    initialState: AgentState? = nil,
    requestOptions: RequestOptions = .init(),
    streamFn: @escaping StreamFn = PiAI.streamSimple,
    maxTurns: Int? = nil,
  ) {
    self.initialState = initialState
    self.requestOptions = requestOptions
    self.streamFn = streamFn
    self.maxTurns = maxTurns
  }
}

public actor Agent {
  public nonisolated let events: AsyncThrowingStream<AgentEvent, any Error>
  private let eventsContinuation: AsyncThrowingStream<AgentEvent, any Error>.Continuation

  private var steeringQueue: [Message] = []
  private var followUpQueue: [Message] = []
  private var steeringMode: QueueMode = .oneAtATime
  private var followUpMode: QueueMode = .oneAtATime

  private var runningTask: Task<Void, any Error>?
  private var requestOptions: RequestOptions
  private var streamFn: StreamFn
  private var maxTurns: Int?
  private var skipInitialSteeringPoll = false

  private var _state: AgentState

  public init(opts: AgentOptions) {
    var captured: AsyncThrowingStream<AgentEvent, any Error>.Continuation?
    events = AsyncThrowingStream(AgentEvent.self, bufferingPolicy: .bufferingNewest(1024)) { continuation in
      captured = continuation
    }
    eventsContinuation = captured!

    streamFn = opts.streamFn
    requestOptions = opts.requestOptions
    maxTurns = opts.maxTurns

    if let state = opts.initialState {
      _state = state
    } else {
      _state = AgentState(model: Model(id: "gpt-4.1-mini", provider: .openai))
    }
  }

  deinit {
    eventsContinuation.finish()
  }

  public var state: AgentState {
    _state
  }

  public func setSystemPrompt(_ v: String) {
    _state.systemPrompt = v
  }

  public func setModel(_ m: Model) {
    _state.model = m
  }

  public func setTools(_ t: [AnyAgentTool]) {
    _state.tools = t
  }

  public func replaceMessages(_ ms: [Message]) {
    _state.messages = ms
  }

  public func appendMessage(_ m: Message) {
    _state.messages.append(m)
  }

  public func clearMessages() {
    _state.messages = []
  }

  public func setSteeringMode(_ mode: QueueMode) {
    steeringMode = mode
  }

  public func setFollowUpMode(_ mode: QueueMode) {
    followUpMode = mode
  }

  public func steer(_ m: Message) {
    steeringQueue.append(m)
  }

  public func followUp(_ m: Message) {
    followUpQueue.append(m)
  }

  public func clearSteeringQueue() {
    steeringQueue = []
  }

  public func clearFollowUpQueue() {
    followUpQueue = []
  }

  public func abort() {
    runningTask?.cancel()
  }

  public func waitForIdle() async {
    _ = try? await runningTask?.value
  }

  public func reset() {
    _state.messages = []
    _state.isStreaming = false
    _state.streamMessage = nil
    _state.pendingToolCalls = []
    _state.error = nil
    steeringQueue = []
    followUpQueue = []
  }

  public func prompt(_ input: String) async throws {
    try await prompt([.user(input)])
  }

  public func prompt(_ messages: [Message]) async throws {
    if _state.isStreaming {
      throw PiAIError.unsupported(
        "Agent is already processing a prompt. Use steer() or followUp() to queue messages, or wait for completion.",
      )
    }
    try await runLoop(prompts: messages, mode: .start)
  }

  public func `continue`() async throws {
    if _state.isStreaming {
      throw PiAIError.unsupported("Agent is already processing. Wait for completion before continuing.")
    }
    guard !_state.messages.isEmpty else { throw AgentLoopContinueError.noMessages }

    if case .assistant = _state.messages.last {
      let queuedSteering = dequeueSteeringMessages()
      if !queuedSteering.isEmpty {
        try await runLoop(prompts: queuedSteering, mode: .start, skipInitialSteeringPoll: true)
        return
      }

      let queuedFollowUp = dequeueFollowUpMessages()
      if !queuedFollowUp.isEmpty {
        try await runLoop(prompts: queuedFollowUp, mode: .start)
        return
      }

      throw AgentLoopContinueError.lastMessageIsAssistant
    }

    try await runLoop(prompts: [], mode: .continue)
  }

  private func runLoop(prompts: [Message], mode: AgentLoopMode, skipInitialSteeringPoll: Bool = false) async throws {
    _state.isStreaming = true
    _state.streamMessage = nil
    _state.error = nil

    self.skipInitialSteeringPoll = skipInitialSteeringPoll

    let task = Task<Void, any Error> {
      defer { Task { await self.finishRun() } }

      let cfg = AgentLoopConfig(
        model: self._state.model,
        requestOptions: self.requestOptions,
        maxTurns: self.maxTurns,
        transformContext: nil,
        getSteeringMessages: { [weak self] in
          guard let self else { return [] }
          return await dequeueSteeringMessagesForLoop()
        },
        getFollowUpMessages: { [weak self] in
          guard let self else { return [] }
          return await dequeueFollowUpMessagesForLoop()
        },
        streamFn: self.streamFn,
      )

      let ctx = AgentContext(
        systemPrompt: self._state.systemPrompt,
        messages: self._state.messages,
        tools: self._state.tools,
      )

      let stream: AsyncThrowingStream<AgentEvent, any Error> = switch mode {
      case .start:
        agentLoop(prompts: prompts, context: ctx, config: cfg)
      case .continue:
        try agentLoopContinue(context: ctx, config: cfg)
      }

      for try await event in stream {
        self.handle(event)
      }
    }

    runningTask = task
    do {
      try await task.value
    } catch {
      throw error
    }
  }

  private func finishRun() async {
    _state.isStreaming = false
    _state.streamMessage = nil
    _state.pendingToolCalls = []
  }

  private func handle(_ event: AgentEvent) {
    eventsContinuation.yield(event)

    switch event {
    case let .messageStart(message):
      if case .assistant = message {
        _state.streamMessage = message
      }

    case let .messageUpdate(message, _):
      if case .assistant = message {
        _state.streamMessage = message
      }

    case let .messageEnd(message):
      _state.streamMessage = nil
      _state.messages.append(message)

    case let .toolExecutionStart(toolCallId, _, _):
      _state.pendingToolCalls.insert(toolCallId)

    case let .toolExecutionEnd(toolCallId, _, _, _):
      _state.pendingToolCalls.remove(toolCallId)

    case let .turnEnd(assistant, _):
      if assistant.stopReason == .error || assistant.stopReason == .aborted {
        _state.error = assistant.errorMessage ?? "Unknown error"
      }

    default:
      break
    }
  }

  private func dequeueSteeringMessages() -> [Message] {
    dequeue(from: &steeringQueue, mode: steeringMode)
  }

  private func dequeueFollowUpMessages() -> [Message] {
    dequeue(from: &followUpQueue, mode: followUpMode)
  }

  private func dequeueSteeringMessagesForLoop() -> [Message] {
    if skipInitialSteeringPoll {
      skipInitialSteeringPoll = false
      return []
    }
    return dequeueSteeringMessages()
  }

  private func dequeueFollowUpMessagesForLoop() -> [Message] {
    dequeueFollowUpMessages()
  }
}

public enum QueueMode: Sendable {
  case all
  case oneAtATime
}

private func dequeue(from queue: inout [Message], mode: QueueMode) -> [Message] {
  switch mode {
  case .oneAtATime:
    if queue.isEmpty { return [] }
    return [queue.removeFirst()]
  case .all:
    let all = queue
    queue.removeAll(keepingCapacity: true)
    return all
  }
}
