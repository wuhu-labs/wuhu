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

private actor StringRecorder {
  var values: [String] = []
  func append(_ v: String) {
    values.append(v)
  }

  func snapshot() -> [String] {
    values
  }
}

private func makeUsage() -> Usage {
  .init(inputTokens: 0, outputTokens: 0, totalTokens: 0)
}

private func makeAssistantMessage(
  content: [AssistantContent],
  stopReason: StopReason = .stop,
) -> AssistantMessage {
  AssistantMessage(
    provider: .openai,
    model: "mock",
    content: content,
    usage: makeUsage(),
    stopReason: stopReason,
  )
}

private func makeUserMessage(_ text: String) -> AgentMessage {
  .llm(.user(.init(content: text)))
}

private func identityConverter(messages: [AgentMessage]) async throws -> [Message] {
  messages.compactMap {
    if case let .llm(m) = $0 { return m }
    return nil
  }
}

private func mockStreamFn(
  select: @escaping @Sendable (_ context: SimpleContext) -> AssistantMessage,
) -> StreamFn {
  { model, context, _ in
    _ = model
    let message = select(context)
    return AsyncThrowingStream { continuation in
      continuation.yield(.start(partial: makeAssistantMessage(content: [])))
      continuation.yield(.done(message: message))
      continuation.finish()
    }
  }
}

struct AgentLoopTests {
  @Test func emitsEventsAndReturnsNewMessages() async {
    let context = AgentContext(systemPrompt: "You are helpful.", messages: [], tools: [])
    let prompt = makeUserMessage("Hello")

    let config = AgentLoopConfig(
      model: .init(id: "gpt-4.1-mini", provider: .openai),
      convertToLlm: identityConverter,
      streamFn: mockStreamFn(select: { _ in makeAssistantMessage(content: [.text(.init(text: "Hi"))]) }),
    )

    var events: [AgentEvent] = []
    let stream = agentLoop(prompts: [prompt], context: context, config: config)
    for await event in stream {
      events.append(event)
    }

    let produced = await stream.result()
    #expect(produced.count == 2)
    #expect(produced[0].role == "user")
    #expect(produced[1].role == "assistant")

    let eventTypes = events.map { "\($0)" }
    #expect(eventTypes.contains(where: { $0.contains("agentStart") }))
    #expect(eventTypes.contains(where: { $0.contains("turnStart") }))
    #expect(eventTypes.contains(where: { $0.contains("messageStart") }))
    #expect(eventTypes.contains(where: { $0.contains("messageEnd") }))
    #expect(eventTypes.contains(where: { $0.contains("turnEnd") }))
    #expect(eventTypes.contains(where: { $0.contains("agentEnd") }))
  }

  @Test func filtersCustomMessagesViaConvertToLlm() async {
    let notification: AgentMessage = .custom(.init(role: "notification", content: "note"))
    let context = AgentContext(systemPrompt: "", messages: [notification], tools: [])
    let prompt = makeUserMessage("Hello")

    let convertedCount = IntBox()
    let config = AgentLoopConfig(
      model: .init(id: "gpt-4.1-mini", provider: .openai),
      convertToLlm: { messages in
        let llm = messages.compactMap { if case let .llm(m) = $0 { m } else { nil } }
        await convertedCount.set(llm.count)
        return llm
      },
      streamFn: mockStreamFn(select: { _ in makeAssistantMessage(content: [.text(.init(text: "Response"))]) }),
    )

    let stream = agentLoop(prompts: [prompt], context: context, config: config)
    for await _ in stream {}
    #expect(await convertedCount.get() == 1) // only the user prompt
  }

  @Test func appliesTransformContextBeforeConvertToLlm() async {
    let context = AgentContext(
      systemPrompt: "",
      messages: [
        makeUserMessage("old 1"),
        .llm(.assistant(makeAssistantMessage(content: [.text(.init(text: "resp 1"))]))),
        makeUserMessage("old 2"),
        .llm(.assistant(makeAssistantMessage(content: [.text(.init(text: "resp 2"))]))),
      ],
      tools: [],
    )

    let prompt = makeUserMessage("new")

    let transformedCount = IntBox()
    let convertedCount = IntBox()

    let config = AgentLoopConfig(
      model: .init(id: "gpt-4.1-mini", provider: .openai),
      convertToLlm: { messages in
        let llm = try await identityConverter(messages: messages)
        await convertedCount.set(llm.count)
        return llm
      },
      transformContext: { messages, _ in
        let pruned = Array(messages.suffix(2))
        await transformedCount.set(pruned.count)
        return pruned
      },
      streamFn: mockStreamFn(select: { _ in makeAssistantMessage(content: [.text(.init(text: "Response"))]) }),
    )

    let stream = agentLoop(prompts: [prompt], context: context, config: config)
    for await _ in stream {}

    #expect(await transformedCount.get() == 2)
    #expect(await convertedCount.get() == 2)
  }

  @Test func handlesToolCallsAndResults() async {
    let schema: JSONValue = .object([
      "type": .string("object"),
      "properties": .object([
        "value": .object(["type": .string("string")]),
      ]),
      "required": .array([.string("value")]),
    ])

    let executed = StringRecorder()
    let tool = AgentTool(
      tool: .init(name: "echo", description: "Echo", parameters: schema),
      label: "Echo",
      execute: { _, params, _, _ in
        let v = params.asObject?["value"]?.asString ?? ""
        await executed.append(v)
        return .init(content: "echoed: \(v)", details: .object(["value": .string(v)]))
      },
    )

    let context = AgentContext(systemPrompt: "", messages: [], tools: [tool])
    let prompt = makeUserMessage("echo something")

    let first = makeAssistantMessage(
      content: [.toolCall(.init(id: "tool-1", name: "echo", arguments: .object(["value": .string("hello")])))],
      stopReason: .toolUse,
    )
    let second = makeAssistantMessage(content: [.text(.init(text: "done"))], stopReason: .stop)

    let config = AgentLoopConfig(
      model: .init(id: "gpt-4.1-mini", provider: .openai),
      convertToLlm: identityConverter,
      streamFn: mockStreamFn(select: { context in
        let hasToolResult = context.messages.contains { message in
          if case .toolResult = message { return true }
          return false
        }
        return hasToolResult ? second : first
      }),
    )

    var events: [AgentEvent] = []
    let stream = agentLoop(prompts: [prompt], context: context, config: config)
    for await event in stream {
      events.append(event)
    }

    #expect(await executed.snapshot() == ["hello"])
    #expect(events.contains(where: { if case .toolExecutionStart = $0 { true } else { false } }))
    #expect(events.contains(where: { if case .toolExecutionEnd = $0 { true } else { false } }))
  }

  @Test func injectsSteeringAndSkipsRemainingTools() async {
    let schema: JSONValue = .object([
      "type": .string("object"),
      "properties": .object([
        "value": .object(["type": .string("string")]),
      ]),
      "required": .array([.string("value")]),
    ])

    let executed = StringRecorder()
    let tool = AgentTool(
      tool: .init(name: "echo", description: "Echo", parameters: schema),
      label: "Echo",
      execute: { _, params, _, _ in
        await executed.append(params.asObject?["value"]?.asString ?? "")
        return .init(content: "ok", details: .object([:]))
      },
    )

    let prompt = makeUserMessage("start")
    let queued = makeUserMessage("interrupt")

    let delivered = BoolBox(false)
    let sawInterruptInContext = BoolBox(false)

    let assistantWithTwoTools = makeAssistantMessage(
      content: [
        .toolCall(.init(id: "tool-1", name: "echo", arguments: .object(["value": .string("first")]))),
        .toolCall(.init(id: "tool-2", name: "echo", arguments: .object(["value": .string("second")]))),
      ],
      stopReason: .toolUse,
    )
    let assistantDone = makeAssistantMessage(content: [.text(.init(text: "done"))], stopReason: .stop)

    let config = AgentLoopConfig(
      model: .init(id: "gpt-4.1-mini", provider: .openai),
      convertToLlm: identityConverter,
      streamFn: { model, ctx, options in
        _ = options
        // second call should include interrupt message in llm context
        if model.provider == .openai,
           ctx.messages.count > 0,
           ctx.messages.contains(where: { m in
             if case let .user(u) = m { return u.content == "interrupt" }
             return false
           })
        {
          await sawInterruptInContext.set(true)
        }
        let hasToolResult = ctx.messages.contains { message in
          if case .toolResult = message { return true }
          return false
        }
        let message = hasToolResult ? assistantDone : assistantWithTwoTools
        return AsyncThrowingStream { continuation in
          continuation.yield(.start(partial: makeAssistantMessage(content: [])))
          continuation.yield(.done(message: message))
          continuation.finish()
        }
      },
      getSteeringMessages: {
        let exec = await executed.snapshot()
        if exec.count == 1, await delivered.get() == false {
          await delivered.set(true)
          return [queued]
        }
        return []
      },
    )

    let context = AgentContext(systemPrompt: "", messages: [], tools: [tool])
    var toolEnds: [Bool] = []
    let stream = agentLoop(prompts: [prompt], context: context, config: config)
    for await event in stream {
      if case let .toolExecutionEnd(_, _, _, isError) = event {
        toolEnds.append(isError)
      }
    }

    #expect(await executed.snapshot() == ["first"])
    #expect(toolEnds.count == 2)
    #expect(toolEnds[0] == false)
    #expect(toolEnds[1] == true)
    #expect(await sawInterruptInContext.get() == true)
  }

  @Test func continueThrowsWithNoMessages() throws {
    let context = AgentContext(systemPrompt: "", messages: [], tools: [])
    let config = AgentLoopConfig(
      model: .init(id: "gpt-4.1-mini", provider: .openai),
      convertToLlm: identityConverter,
      streamFn: mockStreamFn(select: { _ in makeAssistantMessage(content: [.text(.init(text: "x"))]) }),
    )

    do {
      _ = try agentLoopContinue(context: context, config: config)
      #expect(Bool(false))
    } catch let error as AgentError {
      #expect(error == .invalidContinue("Cannot continue: no messages in context"))
    }
  }
}
