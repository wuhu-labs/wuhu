import Foundation
import PiAI
import Testing
import WuhuCore
#if canImport(Darwin)
  import Darwin
#else
  import Glibc
#endif

struct WuhuCoreTests {
  private func withEnv(_ key: String, _ value: String?, operation: () async throws -> Void) async rethrows {
    let old = getenv(key).map { String(cString: $0) }
    if let value {
      setenv(key, value, 1)
    } else {
      unsetenv(key)
    }
    defer {
      if let old {
        setenv(key, old, 1)
      } else {
        unsetenv(key)
      }
    }
    try await operation()
  }

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

  @Test func autoCompactionAppendsEntryAndInjectsSummaryIntoContext() async throws {
    try await withEnv("WUHU_COMPACTION_ENABLED", "1") {
      try await withEnv("WUHU_COMPACTION_CONTEXT_WINDOW_TOKENS", "400") {
        try await withEnv("WUHU_COMPACTION_RESERVE_TOKENS", "100") {
          try await withEnv("WUHU_COMPACTION_KEEP_RECENT_TOKENS", "120") {
            let store = try SQLiteSessionStore(path: ":memory:")
            let service = WuhuService(store: store)

            let session = try await service.createSession(
              provider: .openai,
              model: "mock",
              systemPrompt: "You are helpful.",
              environment: .init(name: "test", type: .local, path: "/tmp"),
            )

            let chunk = String(repeating: "x", count: 220)
            for i in 0 ..< 10 {
              _ = try await store.appendEntry(sessionID: session.id, payload: .message(.fromPi(.user("u\(i) \(chunk)"))))
              let assistant = AssistantMessage(
                provider: .openai,
                model: "mock",
                content: [.text("a\(i) \(chunk)")],
                stopReason: .stop,
              )
              _ = try await store.appendEntry(sessionID: session.id, payload: .message(.fromPi(.assistant(assistant))))
            }

            actor Observations {
              var sawSummaryInjected = false
              func markInjected() {
                sawSummaryInjected = true
              }

              func injected() -> Bool {
                sawSummaryInjected
              }
            }
            let observations = Observations()

            let stream = try await service.promptStream(
              sessionID: session.id,
              input: "hello",
              tools: [],
              streamFn: { model, ctx, _ in
                if ctx.systemPrompt?.contains("context summarization assistant") == true {
                  return AsyncThrowingStream { continuation in
                    Task {
                      let assistant = AssistantMessage(
                        provider: model.provider,
                        model: model.id,
                        content: [.text("SUMMARY")],
                        stopReason: .stop,
                      )
                      continuation.yield(.done(message: assistant))
                      continuation.finish()
                    }
                  }
                }

                let injected = ctx.messages.contains { msg in
                  guard case let .user(u) = msg else { return false }
                  return u.content.contains { block in
                    if case let .text(t) = block { return t.text.contains("SUMMARY") }
                    return false
                  }
                }
                if injected {
                  Task { await observations.markInjected() }
                }

                return AsyncThrowingStream { continuation in
                  Task {
                    let assistant = AssistantMessage(
                      provider: model.provider,
                      model: model.id,
                      content: [.text("ok")],
                      stopReason: .stop,
                    )
                    continuation.yield(.done(message: assistant))
                    continuation.finish()
                  }
                }
              },
            )

            for try await _ in stream {}

            let transcript = try await service.getTranscript(sessionID: session.id)
            let compactions = transcript.compactMap { entry -> WuhuCompaction? in
              if case let .compaction(c) = entry.payload { return c }
              return nil
            }
            #expect(compactions.count >= 1)
            #expect(await observations.injected())
          }
        }
      }
    }
  }

  @Test func getTranscript_sinceCursorAndSinceTimeFilters() async throws {
    let store = try SQLiteSessionStore(path: ":memory:")
    let service = WuhuService(store: store)

    let session = try await service.createSession(
      provider: .openai,
      model: "mock",
      systemPrompt: "You are helpful.",
      environment: .init(name: "test", type: .local, path: "/tmp"),
    )

    let e1 = try await store.appendEntry(sessionID: session.id, payload: .message(.fromPi(.user("one"))))
    let e2 = try await store.appendEntry(sessionID: session.id, payload: .message(.fromPi(.assistant(.init(
      provider: .openai,
      model: "mock",
      content: [.text("two")],
      stopReason: .stop,
    )))))

    let sinceCursor = try await service.getTranscript(sessionID: session.id, sinceCursor: e1.id, sinceTime: nil)
    #expect(sinceCursor.map(\.id) == [e2.id])

    let sinceTimeFuture = try await service.getTranscript(
      sessionID: session.id,
      sinceCursor: nil,
      sinceTime: Date().addingTimeInterval(60),
    )
    #expect(sinceTimeFuture.isEmpty)
  }

  @Test func followSessionStream_stopAfterIdleFinishesAfterPromptCompletes() async throws {
    let store = try SQLiteSessionStore(path: ":memory:")
    let service = WuhuService(store: store)

    let session = try await service.createSession(
      provider: .openai,
      model: "mock",
      systemPrompt: "You are helpful.",
      environment: .init(name: "test", type: .local, path: "/tmp"),
    )

    let slowStream: @Sendable (Model, Context, RequestOptions) -> AsyncThrowingStream<AssistantMessageEvent, any Error> = { model, _, _ in
      AsyncThrowingStream { continuation in
        Task {
          var text = ""
          let base = AssistantMessage(provider: model.provider, model: model.id, content: [.text("")], stopReason: .stop)
          continuation.yield(.start(partial: base))
          for ch in ["H", "i"] {
            try await Task.sleep(nanoseconds: 80_000_000)
            text += ch
            let partial = AssistantMessage(provider: model.provider, model: model.id, content: [.text(text)], stopReason: .stop)
            continuation.yield(.textDelta(delta: ch, partial: partial))
          }
          try await Task.sleep(nanoseconds: 80_000_000)
          let done = AssistantMessage(provider: model.provider, model: model.id, content: [.text(text)], stopReason: .stop)
          continuation.yield(.done(message: done))
          continuation.finish()
        }
      }
    }

    let detached = try await service.promptDetached(
      sessionID: session.id,
      input: "hello",
      tools: [],
      streamFn: slowStream,
    )

    let follow = try await service.followSessionStream(
      sessionID: session.id,
      sinceCursor: detached.userEntry.id,
      sinceTime: nil,
      stopAfterIdle: true,
      timeoutSeconds: 5,
    )

    var sawDelta = false
    var sawIdle = false
    var sawDone = false

    for try await event in follow {
      switch event {
      case .assistantTextDelta:
        sawDelta = true
      case .idle:
        sawIdle = true
      case .done:
        sawDone = true
      default:
        break
      }
    }

    #expect(sawDelta)
    #expect(sawIdle)
    #expect(sawDone)
  }

  @Test func followSessionStream_timeoutFinishes() async throws {
    let store = try SQLiteSessionStore(path: ":memory:")
    let service = WuhuService(store: store)

    let session = try await service.createSession(
      provider: .openai,
      model: "mock",
      systemPrompt: "You are helpful.",
      environment: .init(name: "test", type: .local, path: "/tmp"),
    )

    let follow = try await service.followSessionStream(
      sessionID: session.id,
      sinceCursor: nil,
      sinceTime: nil,
      stopAfterIdle: false,
      timeoutSeconds: 0.2,
    )

    var sawDone = false
    for try await event in follow {
      if case .done = event {
        sawDone = true
      }
    }
    #expect(sawDone)
  }
}
