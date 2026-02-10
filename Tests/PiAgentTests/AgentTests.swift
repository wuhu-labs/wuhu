import Foundation
import PiAgent
import PiAI
import Testing

private actor BoolBox {
  var value: Bool
  init(_ value: Bool = false) {
    self.value = value
  }

  func set(_ v: Bool) {
    value = v
  }

  func get() -> Bool {
    value
  }
}

private actor IntBox {
  var value: Int
  init(_ value: Int = 0) {
    self.value = value
  }

  func set(_ v: Int) {
    value = v
  }

  func get() -> Int {
    value
  }
}

private actor StringBox {
  var value: String?
  func set(_ v: String?) {
    value = v
  }

  func get() -> String? {
    value
  }
}

private func makeAssistantMessage(text: String) -> AssistantMessage {
  AssistantMessage(
    provider: .openai,
    model: "mock",
    content: [.text(.init(text: text))],
    usage: .init(inputTokens: 0, outputTokens: 0, totalTokens: 0),
    stopReason: .stop,
  )
}

private func makeMockStream(finalText: String) -> AsyncThrowingStream<AssistantMessageEvent, any Error> {
  AsyncThrowingStream { continuation in
    let msg = makeAssistantMessage(text: finalText)
    continuation.yield(.start(partial: makeAssistantMessage(text: "")))
    continuation.yield(.textDelta(delta: finalText, partial: msg))
    continuation.yield(.done(message: msg))
    continuation.finish()
  }
}

struct AgentTests {
  @Test func createsDefaultState() {
    let agent = Agent()
    #expect(agent.state.systemPrompt == "")
    #expect(agent.state.model.provider == .openai)
    #expect(agent.state.thinkingLevel == .off)
    #expect(agent.state.tools.isEmpty)
    #expect(agent.state.messages.isEmpty)
    #expect(agent.state.isStreaming == false)
    #expect(agent.state.streamMessage == nil)
    #expect(agent.state.pendingToolCalls.isEmpty)
    #expect(agent.state.error == nil)
  }

  @Test func createsCustomInitialState() {
    let agent = Agent(.init(initialState: .init(
      systemPrompt: "You are a helpful assistant.",
      model: .init(id: "claude-sonnet-4-5", provider: .anthropic),
      thinkingLevel: .low,
    )))

    #expect(agent.state.systemPrompt == "You are a helpful assistant.")
    #expect(agent.state.model.provider == .anthropic)
    #expect(agent.state.thinkingLevel == .low)
  }

  @Test func subscribesAndUnsubscribes() async {
    let agent = Agent()
    let count = IntBox()
    let unsubscribe = agent.subscribe { _ in
      Task {
        await count.set(count.get() + 1)
      }
    }

    agent.setSystemPrompt("x")
    #expect(await count.get() == 0)

    unsubscribe()
    agent.setSystemPrompt("y")
    #expect(await count.get() == 0)
  }

  @Test func updatesStateWithMutators() {
    let agent = Agent()

    agent.setSystemPrompt("Custom")
    #expect(agent.state.systemPrompt == "Custom")

    agent.setModel(.init(id: "claude-sonnet-4-5", provider: .anthropic))
    #expect(agent.state.model.provider == .anthropic)

    agent.setThinkingLevel(.high)
    #expect(agent.state.thinkingLevel == .high)

    agent.setTools([])
    #expect(agent.state.tools.isEmpty)

    let messages: [AgentMessage] = [.llm(.user(.init(content: "Hello")))]
    agent.replaceMessages(messages)
    #expect(agent.state.messages == messages)

    let appended: AgentMessage = .custom(.init(role: "note", content: "Hi"))
    agent.appendMessage(appended)
    #expect(agent.state.messages.count == 2)
    #expect(agent.state.messages.last == appended)

    agent.clearMessages()
    #expect(agent.state.messages.isEmpty)
  }

  @Test func queuesSteeringAndFollowUp() {
    let agent = Agent()
    agent.steer(.llm(.user(.init(content: "Steer"))))
    agent.followUp(.llm(.user(.init(content: "Follow"))))
    // queued messages are not appended to state.messages until a run
    #expect(agent.state.messages.isEmpty)
  }

  @Test func abortDoesNotThrow() {
    let agent = Agent()
    agent.abort()
  }

  @Test func promptThrowsWhenStreaming() async throws {
    let tokenSeen = BoolBox(false)
    let agent = Agent(.init(streamFn: { _, _, _ in
      await tokenSeen.set(true)
      return AsyncThrowingStream { continuation in
        continuation.yield(AssistantMessageEvent.start(partial: makeAssistantMessage(text: "")))
        // never finish until cancelled
      }
    }))

    let firstTask = Task { try await agent.prompt("First") }

    // Give it a moment to set isStreaming.
    try await Task.sleep(nanoseconds: 30_000_000)
    #expect(agent.state.isStreaming == true)
    #expect(await tokenSeen.get() == true)

    do {
      try await agent.prompt("Second")
      #expect(Bool(false))
    } catch let error as AgentError {
      #expect(error == .alreadyProcessingPrompt)
    }

    agent.abort()
    _ = try? await firstTask.value
  }

  @Test func continueThrowsWhenStreaming() async throws {
    let agent = Agent(.init(streamFn: { _, _, _ in
      AsyncThrowingStream { continuation in
        continuation.yield(AssistantMessageEvent.start(partial: makeAssistantMessage(text: "")))
        // never finish
      }
    }))

    let firstTask = Task { try await agent.prompt("First") }
    try await Task.sleep(nanoseconds: 30_000_000)
    #expect(agent.state.isStreaming == true)

    do {
      try await agent.continue()
      #expect(Bool(false))
    } catch let error as AgentError {
      #expect(error == .alreadyProcessingContinue)
    }

    agent.abort()
    _ = try? await firstTask.value
  }

  @Test func forwardsSessionIdToStreamFnOptions() async throws {
    let seenSessionId = StringBox()
    let agent = Agent(.init(
      streamFn: { _, _, options in
        await seenSessionId.set(options.sessionId)
        return makeMockStream(finalText: "ok")
      },
      sessionId: "session-abc",
    ))

    try await agent.prompt("hello")
    #expect(await seenSessionId.get() == "session-abc")

    agent.sessionId = "session-def"
    try await agent.prompt("hello again")
    #expect(await seenSessionId.get() == "session-def")
  }
}
