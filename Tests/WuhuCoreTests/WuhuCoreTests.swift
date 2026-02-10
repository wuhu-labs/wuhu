import Testing
import WuhuCore

struct WuhuCoreTests {
  @Test func createSessionCreatesHeaderAndHeadTail() async throws {
    let store = try SQLiteSessionStore(path: ":memory:")
    let service = WuhuService(store: store)

    let session = try await service.createSession(
      provider: .openai,
      model: "mock",
      systemPrompt: "You are helpful.",
      environment: .init(name: "test", type: .local, path: "/tmp"),
    )

    #expect(session.provider == .openai)
    #expect(session.model == "mock")
    #expect(session.headEntryID == session.tailEntryID)

    let entries = try await service.getTranscript(sessionID: session.id)
    #expect(entries.count == 1)
    #expect(entries[0].id == session.headEntryID)
    #expect(entries[0].parentEntryID == nil)

    guard case let .header(header) = entries[0].payload else {
      #expect(Bool(false))
      return
    }
    #expect(header.systemPrompt == "You are helpful.")
  }

  @Test func promptStreamPersistsLinearChain() async throws {
    let store = try SQLiteSessionStore(path: ":memory:")
    let service = WuhuService(store: store)

    let session = try await service.createSession(
      provider: .openai,
      model: "mock",
      systemPrompt: "You are a terminal agent.",
      environment: .init(name: "test", type: .local, path: "/tmp"),
    )

    actor StreamState {
      var callCount = 0

      func stream(model: Model, ctx: Context, _: RequestOptions) -> AsyncThrowingStream<AssistantMessageEvent, any Error> {
        callCount += 1
        let n = callCount

        return AsyncThrowingStream<AssistantMessageEvent, any Error> { continuation in
          Task {
            if n == 1 {
              let toolCall = ToolCall(
                id: "tool-1",
                name: "weather",
                arguments: .object(["city": .string("Tokyo")]),
              )
              let assistant = AssistantMessage(
                provider: model.provider,
                model: model.id,
                content: [.toolCall(toolCall)],
                stopReason: .toolUse,
              )
              continuation.yield(.done(message: assistant))
              continuation.finish()
              return
            }

            let sawToolResult = ctx.messages.contains(where: { msg in
              if case .toolResult = msg { return true }
              return false
            })

            let text = sawToolResult ? "Tokyo is 29°C (simulated)." : "Missing tool result."
            let assistant = AssistantMessage(
              provider: model.provider,
              model: model.id,
              content: [.text(text)],
              stopReason: .stop,
            )
            continuation.yield(.done(message: assistant))
            continuation.finish()
          }
        }
      }
    }

    let state = StreamState()

    let stream = try await service.promptStream(
      sessionID: session.id,
      input: "What's the weather in Tokyo?",
      maxTurns: 5,
      tools: [WuhuTools.simulatedWeatherTool()],
      streamFn: { model, ctx, opts in
        await state.stream(model: model, ctx: ctx, opts)
      },
    )

    for try await _ in stream {}

    let entries = try await service.getTranscript(sessionID: session.id)
    #expect(entries.count == 7)

    // 1 header + 6 appended entries, all in a single parent-linked chain.
    #expect(entries[0].parentEntryID == nil)
    for i in 1 ..< entries.count {
      #expect(entries[i].parentEntryID == entries[i - 1].id)
    }

    let tail = try await service.getSession(id: session.id).tailEntryID
    #expect(entries.last?.id == tail)
  }
}
