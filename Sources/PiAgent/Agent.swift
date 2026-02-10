import Foundation
import PiAI

public struct AgentOptions: Sendable {
  public var initialState: AgentState?
  public var convertToLlm: ConvertToLlm?
  public var transformContext: TransformContext?
  public var steeringMode: QueueMode
  public var followUpMode: QueueMode
  public var streamFn: StreamFn?
  public var sessionId: String?
  public var getApiKey: (@Sendable (_ provider: Provider) async throws -> String?)?
  public var requestOptions: RequestOptions

  public init(
    initialState: AgentState? = nil,
    convertToLlm: ConvertToLlm? = nil,
    transformContext: TransformContext? = nil,
    steeringMode: QueueMode = .oneAtATime,
    followUpMode: QueueMode = .oneAtATime,
    streamFn: StreamFn? = nil,
    sessionId: String? = nil,
    getApiKey: (@Sendable (_ provider: Provider) async throws -> String?)? = nil,
    requestOptions: RequestOptions = .init(),
  ) {
    self.initialState = initialState
    self.convertToLlm = convertToLlm
    self.transformContext = transformContext
    self.steeringMode = steeringMode
    self.followUpMode = followUpMode
    self.streamFn = streamFn
    self.sessionId = sessionId
    self.getApiKey = getApiKey
    self.requestOptions = requestOptions
  }
}

public enum QueueMode: Sendable {
  case all
  case oneAtATime
}

public final class Agent: @unchecked Sendable {
  private struct Storage: Sendable {
    var state: AgentState
    var listeners: [UUID: @Sendable (AgentEvent) -> Void]
    var steeringQueue: [AgentMessage]
    var followUpQueue: [AgentMessage]
    var cancellationToken: CancellationToken?
    var runningTask: Task<Void, Never>?
    var sessionId: String?
  }

  private let storage: Mutex<Storage>

  public var state: AgentState {
    storage.withLock { $0.state }
  }

  private let convertToLlm: ConvertToLlm
  private let transformContext: TransformContext?
  private let steeringMode: QueueMode
  private let followUpMode: QueueMode
  public var streamFn: StreamFn
  private let getApiKey: (@Sendable (_ provider: Provider) async throws -> String?)?
  private var requestOptions: RequestOptions

  public init(_ options: AgentOptions = .init()) {
    let initial = options.initialState ?? AgentState()
    storage = Mutex(initialState: .init(
      state: initial,
      listeners: [:],
      steeringQueue: [],
      followUpQueue: [],
      cancellationToken: nil,
      runningTask: nil,
      sessionId: options.sessionId,
    ))
    convertToLlm = options.convertToLlm ?? Agent.defaultConvertToLlm
    transformContext = options.transformContext
    steeringMode = options.steeringMode
    followUpMode = options.followUpMode
    streamFn = options.streamFn ?? DefaultStream.stream
    getApiKey = options.getApiKey
    requestOptions = options.requestOptions
  }

  public var sessionId: String? {
    get {
      storage.withLock { $0.sessionId }
    }
    set {
      storage.withLock { $0.sessionId = newValue }
    }
  }

  public func subscribe(_ fn: @escaping @Sendable (AgentEvent) -> Void) -> @Sendable () -> Void {
    let id = UUID()
    storage.withLock { $0.listeners[id] = fn }
    return { [weak self] in
      self?.storage.withLock { $0.listeners.removeValue(forKey: id) }
    }
  }

  private func emit(_ event: AgentEvent) {
    let fns = storage.withLock { Array($0.listeners.values) }
    for fn in fns {
      fn(event)
    }
  }

  // MARK: - State mutators (do not emit events)

  public func setSystemPrompt(_ v: String) {
    storage.withLock { $0.state.systemPrompt = v }
  }

  public func setModel(_ m: Model) {
    storage.withLock { $0.state.model = m }
  }

  public func setThinkingLevel(_ l: ThinkingLevel) {
    storage.withLock { $0.state.thinkingLevel = l }
  }

  public func setTools(_ t: [AgentTool]) {
    storage.withLock { $0.state.tools = t }
  }

  public func replaceMessages(_ ms: [AgentMessage]) {
    storage.withLock { $0.state.messages = ms }
  }

  public func appendMessage(_ m: AgentMessage) {
    storage.withLock { $0.state.messages.append(m) }
  }

  public func clearMessages() {
    storage.withLock { $0.state.messages = [] }
  }

  // MARK: - Queues

  public func steer(_ m: AgentMessage) {
    storage.withLock { $0.steeringQueue.append(m) }
  }

  public func followUp(_ m: AgentMessage) {
    storage.withLock { $0.followUpQueue.append(m) }
  }

  private func dequeueSteering() -> [AgentMessage] {
    storage.withLock {
      switch steeringMode {
      case .oneAtATime:
        guard let first = $0.steeringQueue.first else { return [] }
        $0.steeringQueue.removeFirst()
        return [first]
      case .all:
        let out = $0.steeringQueue
        $0.steeringQueue = []
        return out
      }
    }
  }

  private func dequeueFollowUp() -> [AgentMessage] {
    storage.withLock {
      switch followUpMode {
      case .oneAtATime:
        guard let first = $0.followUpQueue.first else { return [] }
        $0.followUpQueue.removeFirst()
        return [first]
      case .all:
        let out = $0.followUpQueue
        $0.followUpQueue = []
        return out
      }
    }
  }

  public func abort() {
    let (token, task) = storage.withLock { ($0.cancellationToken, $0.runningTask) }
    token?.cancel()
    task?.cancel()
  }

  public func waitForIdle() async {
    let task = storage.withLock { $0.runningTask }
    _ = await task?.value
  }

  public func reset() {
    storage.withLock {
      $0.state.messages = []
      $0.state.isStreaming = false
      $0.state.streamMessage = nil
      $0.state.pendingToolCalls = []
      $0.state.error = nil
      $0.steeringQueue = []
      $0.followUpQueue = []
    }
  }

  public func prompt(_ input: String) async throws {
    let message = AgentMessage.llm(.user(.init(content: input)))
    try await prompt(message)
  }

  public func prompt(_ message: AgentMessage) async throws {
    try await prompt([message])
  }

  public func prompt(_ messages: [AgentMessage]) async throws {
    let started = storage.withLock { storage in
      if storage.state.isStreaming { return false }
      storage.state.isStreaming = true
      storage.state.error = nil
      return true
    }
    guard started else { throw AgentError.alreadyProcessingPrompt }

    let token = CancellationToken()
    let (systemPrompt, existingMessages, tools) = storage.withLock { ($0.state.systemPrompt, $0.state.messages, $0.state.tools) }
    storage.withLock { $0.cancellationToken = token }

    let loopConfig = makeLoopConfig(token: token)
    let ctx = AgentContext(systemPrompt: systemPrompt, messages: existingMessages, tools: tools)
    let stream = agentLoop(prompts: messages, context: ctx, config: loopConfig, cancellationToken: token)

    let task = Task {
      for await event in stream {
        emit(event)
        if case let .messageUpdate(message, _) = event {
          storage.withLock { $0.state.streamMessage = message }
        }
      }

      let produced = await stream.result()
      storage.withLock {
        $0.state.messages.append(contentsOf: produced)
        $0.state.isStreaming = false
        $0.state.streamMessage = nil
        $0.cancellationToken = nil
        $0.runningTask = nil
      }
    }

    storage.withLock { $0.runningTask = task }
    await task.value
  }

  public func `continue`() async throws {
    let (existing, systemPrompt, tools, alreadyStreaming): ([AgentMessage], String, [AgentTool], Bool) = storage.withLock {
      let already = $0.state.isStreaming
      if !already {
        $0.state.isStreaming = true
        $0.state.error = nil
      }
      return ($0.state.messages, $0.state.systemPrompt, $0.state.tools, already)
    }
    if alreadyStreaming {
      throw AgentError.alreadyProcessingContinue
    }

    let token = CancellationToken()
    storage.withLock { $0.cancellationToken = token }

    let loopConfig = makeLoopConfig(token: token)
    let ctx = AgentContext(systemPrompt: systemPrompt, messages: existing, tools: tools)
    let stream = try agentLoopContinue(context: ctx, config: loopConfig, cancellationToken: token)

    let task = Task {
      for await event in stream {
        emit(event)
        if case let .messageUpdate(message, _) = event {
          storage.withLock { $0.state.streamMessage = message }
        }
      }
      let produced = await stream.result()
      storage.withLock {
        $0.state.messages.append(contentsOf: produced)
        $0.state.isStreaming = false
        $0.state.streamMessage = nil
        $0.cancellationToken = nil
        $0.runningTask = nil
      }
    }

    storage.withLock { $0.runningTask = task }

    await task.value
  }

  private func makeLoopConfig(token _: CancellationToken) -> AgentLoopConfig {
    let model = storage.withLock { $0.state.model }
    return AgentLoopConfig(
      model: model,
      convertToLlm: convertToLlm,
      transformContext: transformContext,
      streamFn: streamFn,
      requestOptions: resolvedRequestOptions(),
      getApiKey: getApiKey,
      getSteeringMessages: { [weak self] in
        guard let self else { return [] }
        return dequeueSteering()
      },
      getFollowUpMessages: { [weak self] in
        guard let self else { return [] }
        return dequeueFollowUp()
      },
    )
  }

  private func resolvedRequestOptions() -> RequestOptions {
    var options = requestOptions
    options.sessionId = sessionId
    return options
  }

  private static func defaultConvertToLlm(_ messages: [AgentMessage]) async throws -> [Message] {
    messages.compactMap { message in
      if case let .llm(m) = message {
        return m
      }
      return nil
    }
  }
}
