import Clocks
import Fetch
import FetchWebSocket
#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import JSONValue
import OrderedCollections

public actor ResponsesWebSocketSession {
  private var quotaReceiver: (@Sendable (JSONValue) async -> Void)?
  private var generation = 0
  private var socket: WebSocketConnection?
  private var socketIdentity: SocketIdentity?
  private var pump: Task<Void, Never>?
  private var inFlight: UUID?
  private var lastAttempt: UUID?
  private var active: ActiveResponse?
  private var candidate: Candidate?
  private var memo: Memo?
  private var activity = 0
  private var lastFailure: (generation: Int, error: any Error)?

  public init() {}

  public func invalidate() {
    quotaReceiver = nil
    generation += 1
    socket?.abort()
    socket = nil
    socketIdentity = nil
    pump?.cancel()
    pump = nil
    active?.events.finish(throwing: WebSocketError.connectionClosed)
    active = nil
    candidate = nil
    memo = nil
  }

  public func acknowledge(
    attemptID: String,
    committedMessage: AssistantMessage,
    toolCallIDs: [String: String],
    renderedContext: Context,
  ) async {
    guard inFlight == nil, let candidate, candidate.attemptID == attemptID,
          candidate.generation == generation else { return }
    self.candidate = nil
    var projected = candidate.message
    var expectedIDs: Set<String> = []
    for index in projected.content.indices {
      if case var .toolCall(call) = projected.content[index] {
        expectedIDs.insert(call.id)
        guard let replacement = toolCallIDs[call.id] else { memo = nil; return }
        call.id = replacement
        projected.content[index] = .toolCall(call)
      }
    }
    guard Set(toolCallIDs.keys) == expectedIDs, Set(toolCallIDs.values).count == toolCallIDs.count,
          projected == committedMessage,
          renderedContext.systemPrompt == candidate.context.systemPrompt,
          renderedContext.tools == candidate.context.tools,
          renderedContext.messages == candidate.context.messages + [.assistant(committedMessage)]
    else { memo = nil; return }
    do {
      let baseline = try await candidate.build(renderedContext)
      guard generation == candidate.generation, lastAttempt == candidate.token, inFlight == nil else { return }
      guard let originalInput = candidate.body["input"]?.array, let baselineInput = baseline.body["input"]?.array,
            Array(baselineInput.prefix(originalInput.count)) == originalInput,
            properties(baseline.body) == properties(candidate.body)
      else { memo = nil; return }
      var aliases = candidate.aliases
      for (provider, kernel) in toolCallIDs { aliases[wireToolCallID(kernel)] = provider }
      memo = Memo(responseID: candidate.responseID, context: renderedContext, body: baseline.body, aliases: aliases)
    } catch { if lastAttempt == candidate.token { memo = nil } }
  }

  func infer(
    attemptID: String, context: Context,
    build: @escaping @Sendable (Context) async throws -> ResponsesSocketRequest,
    connector: WebSocketConnector, providerID: String, model: String,
    observer: ResponsesWebSocketObserver,
    receiveHeaders: @escaping @Sendable ([String: String]) async -> Void,
    receiveQuota: @escaping @Sendable (JSONValue) async -> Void,
    idleTimeout: Duration?, clock: AnyClock<Duration>,
    yield: @escaping @Sendable (InferenceEvent) -> Void,
  ) async throws -> InferenceEvent {
    guard inFlight == nil else { throw InferenceError.invalidInput(status: 409, body: "A Responses inference is already active") }
    let token = UUID()
    inFlight = token
    lastAttempt = token
    let startingGeneration = generation
    candidate = nil
    defer { if inFlight == token { inFlight = nil } }
    do {
      return try await withTaskCancellationHandler {
        try await withThrowingTaskGroup(of: InferenceEvent.self) { group in
          if let idleTimeout {
            group.addTask {
              var previous = await self.activity
              while true {
                try await clock.sleep(for: idleTimeout)
                let current = await self.activity
                guard current != previous else { throw InferenceError.transport(.idleTimeout) }
                previous = current
              }
            }
          }
          group.addTask {
            return try await self.perform(
              attemptID: attemptID, token: token, startingGeneration: startingGeneration, context: context, build: build, connector: connector,
              providerID: providerID, model: model, observer: observer, receiveHeaders: receiveHeaders, receiveQuota: receiveQuota, yield: yield,
            )
          }
          let terminal = try await group.next()!
          group.cancelAll()
          return terminal
        }
      } onCancel: {
        Task { await self.cancel(token) }
      }
    } catch {
      cancel(token)
      throw error
    }
  }

  private func cancel(_ token: UUID) {
    guard inFlight == token else { return }
    invalidate()
    inFlight = nil
  }

  private func perform(
    attemptID: String, token: UUID, startingGeneration: Int, context: Context,
    build: @escaping @Sendable (Context) async throws -> ResponsesSocketRequest,
    connector: WebSocketConnector, providerID: String, model: String,
    observer: ResponsesWebSocketObserver,
    receiveHeaders: @escaping @Sendable ([String: String]) async -> Void,
    receiveQuota: @escaping @Sendable (JSONValue) async -> Void,
    yield: @escaping @Sendable (InferenceEvent) -> Void,
  ) async throws -> InferenceEvent {
    let request = try await build(context)
    try Task.checkCancellation()
    guard inFlight == token, generation == startingGeneration else { throw WebSocketError.connectionClosed }
    let identity = SocketIdentity(request: request, providerID: providerID, model: model)
    if let socketIdentity, socketIdentity != identity { invalidate() }
    let chain = continuationBody(request.body, context: context)
    memo = nil
    var body = chain.body
    var aliases = chain.aliases
    for subattempt in 1 ... 2 {
      let text = JSONValue.object(body).jsonString()
      guard text.utf8.count <= request.handshake.limits.outboundMessageBytes else {
        throw InferenceError.requestTooLarge(limitBytes: request.handshake.limits.outboundMessageBytes)
      }
      quotaReceiver = receiveQuota
      let connection = try await connection(request: request, identity: identity, connector: connector, token: token)
      let currentGeneration = generation
      await receiveHeaders(RequestHeaders(connection.responseHeaders).values)
      try Task.checkCancellation()
      guard generation == currentGeneration, inFlight == token else { throw WebSocketError.connectionClosed }
      let events = ResponsesEventBuffer()
      active = ActiveResponse(events: events, validator: .init(), observer: observer, receiveHeaders: receiveHeaders, subattempt: subattempt)
      await observer.request(subattempt, request.handshake.headers, .object(body))
      try Task.checkCancellation()
      guard generation == currentGeneration, inFlight == token, active?.events === events else { throw WebSocketError.connectionClosed }
      try await connection.send(.text(text))
      activity += 1
      var terminal: InferenceEvent?
      do {
        for try await event in parseResponsesStream(events.stream, providerID: providerID, model: model, finiteResponse: true) {
          try Task.checkCancellation()
          guard generation == currentGeneration || events.completion != nil else {
            if let lastFailure, lastFailure.generation == currentGeneration { throw lastFailure.error }
            throw WebSocketError.connectionClosed
          }
          if case .done = event { terminal = event } else { yield(event) }
        }
        guard let terminal, case let .done(completed, _) = terminal, let completion = events.completion else {
          throw ResponsesWebSocketEvents.invalid("Missing terminal response identity")
        }
        let continuable = completion.continuable && generation == currentGeneration && socket != nil
        if active?.events === events { active = nil }
        candidate = continuable ? Candidate(
          attemptID: attemptID, token: token, generation: currentGeneration, responseID: completion.responseID,
          message: completed, context: context, body: request.body, aliases: aliases, build: build,
        ) : nil
        return terminal
      } catch let recovery as ResponsesRecovery {
        guard subattempt == 1, recovery == .connectionExpired || body["previous_response_id"] != nil else { throw recovery }
        if recovery == .connectionExpired { invalidate() }
        active = nil
        body = request.body
        aliases = [:]
      }
    }
    throw ResponsesRecovery.previousMissing
  }

  private func connection(
    request: ResponsesSocketRequest, identity: SocketIdentity, connector: WebSocketConnector, token: UUID,
  ) async throws -> WebSocketConnection {
    if socket == nil {
      let currentGeneration = generation
      let connection = try await connector.connect(request.handshake)
      guard currentGeneration == generation, inFlight == token, !Task.isCancelled else {
        connection.abort()
        throw CancellationError()
      }
      socket = connection
      socketIdentity = identity
      pump = Task { [weak self] in
        do {
          for try await event in connection.inbound {
            guard let self else { connection.abort(); return }
            await self.receive(event, generation: currentGeneration)
          }
          await self?.disconnected(WebSocketError.connectionClosed, generation: currentGeneration)
        } catch {
          await self?.disconnected(error, generation: currentGeneration)
        }
      }
    }
    guard let connection = socket else { throw WebSocketError.connectionClosed }
    return connection
  }

  private func receive(_ event: WebSocketEvent, generation receivedGeneration: Int) async {
    guard generation == receivedGeneration else { return }
    activity += 1
    switch event {
    case .closed:
      disconnected(WebSocketError.connectionClosed, generation: receivedGeneration)
    case .message(let message):
      let responseAtArrival = active
      if let response = responseAtArrival {
        await response.observer.received(response.subattempt, message)
        guard generation == receivedGeneration else { return }
      }
      guard case let .text(text) = message, let value = JSONValue.parse(text) else {
        if let response = responseAtArrival, active?.events !== response.events { return }
        disconnected(ResponsesWebSocketEvents.invalid("Expected a text JSON WebSocket message"), generation: receivedGeneration)
        return
      }
      if value.object?["type"]?.stringValue == "codex.rate_limits" {
        await quotaReceiver?(value)
        guard generation == receivedGeneration else { return }
      }
      guard var response = responseAtArrival else {
        if value.object?["type"]?.stringValue == "codex.rate_limits" { return }
        disconnected(ResponsesWebSocketEvents.invalid("Unsolicited Responses event"), generation: receivedGeneration)
        return
      }
      guard active?.events === response.events else { return }
      await response.observer.event(response.subattempt, value)
      guard generation == receivedGeneration, active?.events === response.events else { return }
      if value.object?["type"]?.stringValue == "codex.response.metadata", let headers = value.object?["headers"]?.object {
        await response.receiveHeaders(Dictionary(uniqueKeysWithValues: headers.compactMap { key, value in value.stringValue.map { (key, $0) } }))
      }
      guard generation == receivedGeneration, active?.events === response.events else { return }
      do {
        guard !response.terminal || value.object?["type"]?.stringValue == "codex.rate_limits" else {
          disconnected(ResponsesWebSocketEvents.invalid("Responses event after terminal"), generation: receivedGeneration)
          return
        }
        let accepted = try response.validator.accept(value)
        response.terminal = response.terminal || accepted.terminal
        active = response
        if let event = accepted.event {
          try response.events.yield(event)
        }
        if accepted.terminal, let responseID = response.validator.responseID { response.events.complete(responseID: responseID, continuable: response.validator.continuable) }
      } catch {
        active = response
        response.events.finish(throwing: error)
      }
    }
  }

  private func disconnected(_ error: any Error, generation receivedGeneration: Int) {
    guard generation == receivedGeneration else { return }
    lastFailure = (receivedGeneration, error)
    active?.events.finish(throwing: error)
    invalidate()
  }

  private func continuationBody(_ full: OrderedDictionary<String, JSONValue>, context: Context) -> (body: OrderedDictionary<String, JSONValue>, aliases: [String: String]) {
    guard let memo, socket != nil,
          context.systemPrompt == memo.context.systemPrompt, context.tools == memo.context.tools,
          Array(context.messages.prefix(memo.context.messages.count)) == memo.context.messages,
          let baseline = memo.body["input"]?.array, let input = full["input"]?.array,
          input.count >= baseline.count, Array(input.prefix(baseline.count)) == baseline,
          properties(full) == properties(memo.body), !containsRemoteImage(.object(full))
    else { return (full, [:]) }
    var delta = Array(input.dropFirst(baseline.count))
    for index in delta.indices {
      if var item = delta[index].object, item["type"]?.stringValue == "function_call_output",
         let kernel = item["call_id"]?.stringValue, let provider = memo.aliases[kernel]
      {
        item["call_id"] = .string(provider)
        delta[index] = .object(item)
      }
    }
    var body = full
    body["input"] = .array(delta)
    body["previous_response_id"] = .string(memo.responseID)
    return (body, memo.aliases)
  }
}

private struct ActiveResponse: Sendable {
  var events: ResponsesEventBuffer
  var validator: ResponsesWebSocketEvents
  var observer: ResponsesWebSocketObserver
  var receiveHeaders: @Sendable ([String: String]) async -> Void
  var subattempt: Int
  var terminal = false
}

private struct Candidate: Sendable {
  var attemptID: String
  var token: UUID
  var generation: Int
  var responseID: String
  var message: AssistantMessage
  var context: Context
  var body: OrderedDictionary<String, JSONValue>
  var aliases: [String: String]
  var build: @Sendable (Context) async throws -> ResponsesSocketRequest
}

private struct Memo: Sendable {
  var responseID: String
  var context: Context
  var body: OrderedDictionary<String, JSONValue>
  var aliases: [String: String]
}

private func properties(_ body: OrderedDictionary<String, JSONValue>) -> OrderedDictionary<String, JSONValue> {
  var body = body
  body.removeValue(forKey: "input")
  return body
}

private func containsRemoteImage(_ value: JSONValue) -> Bool {
  if let object = value.object {
    if let url = object["image_url"]?.stringValue, url.hasPrefix("http://") || url.hasPrefix("https://") { return true }
    return object.values.contains(where: containsRemoteImage)
  }
  return value.array?.contains(where: containsRemoteImage) ?? false
}

private struct SocketIdentity: Equatable, Sendable {
  var providerID: String
  var model: String
  var url: URL
  var headers: [String: String]
  var credentials: [String: String]

  init(request: ResponsesSocketRequest, providerID: String, model: String) {
    self.providerID = providerID
    self.model = model
    url = request.handshake.url
    headers = request.handshake.headers.values
    credentials = request.handshake.headers.sensitiveValues
  }
}
