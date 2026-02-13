import Foundation
import PiAgent
import PiAI
import Testing
import WuhuAPI
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

  private func newSessionID() -> String {
    UUID().uuidString.lowercased()
  }

  @Test func createSessionCreatesHeaderAndHeadTail() async throws {
    let store = try SQLiteSessionStore(path: ":memory:")
    let service = WuhuService(store: store)

    let session = try await service.createSession(
      sessionID: newSessionID(),
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

  @Test func createSessionPersistsReasoningEffortInHeaderMetadata() async throws {
    let store = try SQLiteSessionStore(path: ":memory:")
    let service = WuhuService(store: store)

    let session = try await service.createSession(
      sessionID: newSessionID(),
      provider: .openai,
      model: "gpt-5.2-codex",
      reasoningEffort: .medium,
      systemPrompt: "You are helpful.",
      environment: .init(name: "test", type: .local, path: "/tmp"),
    )

    let entries = try await service.getTranscript(sessionID: session.id)
    #expect(entries.count == 1)

    guard case let .header(header) = entries[0].payload else {
      #expect(Bool(false))
      return
    }

    let meta = header.metadata.object?["reasoningEffort"]?.stringValue
    #expect(meta == "medium")
  }

  @Test func promptStreamUsesHeaderReasoningEffortWhenPresent() async throws {
    let store = try SQLiteSessionStore(path: ":memory:")
    let service = WuhuService(store: store)

    let session = try await service.createSession(
      sessionID: newSessionID(),
      provider: .openai,
      model: "gpt-5.2-codex",
      reasoningEffort: .high,
      systemPrompt: "You are helpful.",
      environment: .init(name: "test", type: .local, path: "/tmp"),
    )

    actor Capture {
      var last: RequestOptions?

      func stream(model: Model, ctx _: Context, options: RequestOptions) -> AsyncThrowingStream<AssistantMessageEvent, any Error> {
        last = options
        return AsyncThrowingStream { continuation in
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
    }

    let capture = Capture()

    let stream = try await service.promptStream(
      sessionID: session.id,
      input: "hi",
      user: "test",
      tools: nil,
      streamFn: { model, ctx, options in
        await capture.stream(model: model, ctx: ctx, options: options)
      },
    )
    for try await _ in stream {}

    let last = await capture.last
    #expect(last?.reasoningEffort == .high)
  }

  @Test func promptStreamRetriesLLMRequestsAndAppendsCustomEntries() async throws {
    let store = try SQLiteSessionStore(path: ":memory:")
    let service = WuhuService(
      store: store,
      retryPolicy: .init(
        maxRetries: 5,
        initialBackoffSeconds: 0,
        maxBackoffSeconds: 0,
        jitterFraction: 0,
        sleep: { _ in },
      ),
    )

    let session = try await service.createSession(
      sessionID: newSessionID(),
      provider: .openai,
      model: "mock",
      systemPrompt: "You are helpful.",
      environment: .init(name: "test", type: .local, path: "/tmp"),
    )

    actor Attempts {
      var n = 0
      func next() -> Int {
        n += 1
        return n
      }
    }
    let attempts = Attempts()

    let baseStreamFn: StreamFn = { model, _, _ in
      let attempt = await attempts.next()
      if attempt <= 2 {
        throw PiAIError.unsupported("transient error \(attempt)")
      }

      return AsyncThrowingStream { continuation in
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

    let stream = try await service.promptStream(
      sessionID: session.id,
      input: "hi",
      user: "test",
      tools: nil,
      streamFn: baseStreamFn,
    )
    for try await _ in stream {}

    let entries = try await service.getTranscript(sessionID: session.id)
    let retryCount = entries.count(where: {
      if case let .custom(customType, _) = $0.payload {
        return customType == WuhuLLMCustomEntryTypes.retry
      }
      return false
    })
    let giveUpCount = entries.count(where: {
      if case let .custom(customType, _) = $0.payload {
        return customType == WuhuLLMCustomEntryTypes.giveUp
      }
      return false
    })

    #expect(retryCount == 2)
    #expect(giveUpCount == 0)
    #expect(entries.contains { if case let .message(.assistant(a)) = $0.payload { return a.content.contains { if case .text = $0 { return true }; return false } }; return false })
  }

  @Test func promptStreamGivesUpAfterMaxRetriesAndAppendsGiveUpEntry() async throws {
    let store = try SQLiteSessionStore(path: ":memory:")
    let service = WuhuService(
      store: store,
      retryPolicy: .init(
        maxRetries: 5,
        initialBackoffSeconds: 0,
        maxBackoffSeconds: 0,
        jitterFraction: 0,
        sleep: { _ in },
      ),
    )

    let session = try await service.createSession(
      sessionID: newSessionID(),
      provider: .openai,
      model: "mock",
      systemPrompt: "You are helpful.",
      environment: .init(name: "test", type: .local, path: "/tmp"),
    )

    let alwaysFail: StreamFn = { _, _, _ in
      throw PiAIError.unsupported("permanent failure")
    }

    let stream = try await service.promptStream(
      sessionID: session.id,
      input: "hi",
      user: "test",
      tools: nil,
      streamFn: alwaysFail,
    )

    do {
      for try await _ in stream {}
      #expect(Bool(false))
    } catch {
      // expected
    }

    let entries = try await service.getTranscript(sessionID: session.id)
    let retryCount = entries.count(where: {
      if case let .custom(customType, _) = $0.payload {
        return customType == WuhuLLMCustomEntryTypes.retry
      }
      return false
    })
    let giveUpCount = entries.count(where: {
      if case let .custom(customType, _) = $0.payload {
        return customType == WuhuLLMCustomEntryTypes.giveUp
      }
      return false
    })

    #expect(retryCount == 5)
    #expect(giveUpCount == 1)
  }

  @Test func setSessionModelAppendsSessionSettingsAndUpdatesFuturePrompts() async throws {
    let store = try SQLiteSessionStore(path: ":memory:")
    let service = WuhuService(store: store)

    let session = try await service.createSession(
      sessionID: newSessionID(),
      provider: .openai,
      model: "gpt-5.2-codex",
      reasoningEffort: .high,
      systemPrompt: "You are helpful.",
      environment: .init(name: "test", type: .local, path: "/tmp"),
    )

    let response = try await service.setSessionModel(
      sessionID: session.id,
      request: .init(provider: .openai, model: "gpt-5.1-codex", reasoningEffort: .medium),
    )
    #expect(response.applied == true)
    #expect(response.selection.model == "gpt-5.1-codex")
    #expect(response.selection.reasoningEffort == .medium)

    let updatedSession = try await service.getSession(id: session.id)
    #expect(updatedSession.model == "gpt-5.1-codex")

    let transcript = try await service.getTranscript(sessionID: session.id)
    #expect(transcript.contains(where: { if case .sessionSettings = $0.payload { return true }; return false }))

    actor Capture {
      var lastModelID: String?
      var lastOptions: RequestOptions?

      func stream(model: Model, ctx _: Context, options: RequestOptions) -> AsyncThrowingStream<AssistantMessageEvent, any Error> {
        lastModelID = model.id
        lastOptions = options
        return AsyncThrowingStream { continuation in
          let assistant = AssistantMessage(provider: model.provider, model: model.id, content: [.text("ok")], stopReason: .stop)
          continuation.yield(.done(message: assistant))
          continuation.finish()
        }
      }
    }

    let capture = Capture()
    let stream = try await service.promptStream(
      sessionID: session.id,
      input: "hi",
      tools: nil,
      streamFn: { model, ctx, options in
        await capture.stream(model: model, ctx: ctx, options: options)
      },
    )
    for try await _ in stream {}

    #expect(await capture.lastModelID == "gpt-5.1-codex")
    #expect(await capture.lastOptions?.reasoningEffort == .medium)
  }

  @Test func setSessionModelWhilePromptActiveDefersUntilIdle() async throws {
    let store = try SQLiteSessionStore(path: ":memory:")
    let service = WuhuService(store: store)

    let session = try await service.createSession(
      sessionID: newSessionID(),
      provider: .openai,
      model: "gpt-5.2-codex",
      systemPrompt: "You are helpful.",
      environment: .init(name: "test", type: .local, path: "/tmp"),
    )

    actor Gate {
      var started = false
      private var continuation: CheckedContinuation<Void, Never>?

      func waitUntilStarted() async {
        while !started {
          await Task.yield()
        }
      }

      func wait() async {
        if continuation == nil, started {
          // already waiting
        }
        started = true
        if continuation == nil {
          await withCheckedContinuation { c in
            continuation = c
          }
        }
      }

      func release() {
        continuation?.resume()
        continuation = nil
      }
    }

    let gate = Gate()

    let stream = try await service.promptStream(
      sessionID: session.id,
      input: "hi",
      tools: nil,
      streamFn: { model, _, _ in
        AsyncThrowingStream { continuation in
          Task {
            await gate.wait()
            let assistant = AssistantMessage(provider: model.provider, model: model.id, content: [.text("ok")], stopReason: .stop)
            continuation.yield(.done(message: assistant))
            continuation.finish()
          }
        }
      },
    )

    let consumeTask = Task {
      for try await event in stream {
        if case .done = event { break }
      }
    }

    await gate.waitUntilStarted()

    let response = try await service.setSessionModel(
      sessionID: session.id,
      request: .init(provider: .openai, model: "gpt-5.1-codex", reasoningEffort: .low),
    )
    #expect(response.applied == false)

    await gate.release()
    try await consumeTask.value

    var finalModel: String?
    for _ in 0 ..< 200 {
      let s = try await service.getSession(id: session.id)
      finalModel = s.model
      if s.model == "gpt-5.1-codex" { break }
      await Task.yield()
    }

    #expect(finalModel == "gpt-5.1-codex")
  }

  @Test func promptStreamPersistsLinearChain() async throws {
    let store = try SQLiteSessionStore(path: ":memory:")
    let service = WuhuService(store: store)

    let session = try await service.createSession(
      sessionID: newSessionID(),
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
              sessionID: newSessionID(),
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
      sessionID: newSessionID(),
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
      sessionID: newSessionID(),
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
      sessionID: newSessionID(),
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

  @Test func groupChat_escalatesOnSecondUserAndPrefixesOnlyAfterReminder() async throws {
    let store = try SQLiteSessionStore(path: ":memory:")
    let service = WuhuService(store: store)

    let session = try await service.createSession(
      sessionID: newSessionID(),
      provider: .openai,
      model: "mock",
      systemPrompt: "You are helpful.",
      environment: .init(name: "test", type: .local, path: "/tmp"),
    )

    actor Captures {
      var ctxByCall: [Int: Context] = [:]
      var callCount = 0

      func stream(model: Model, ctx: Context, _: RequestOptions) -> AsyncThrowingStream<AssistantMessageEvent, any Error> {
        callCount += 1
        ctxByCall[callCount] = ctx

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
      }

      func context(forCall n: Int) -> Context? {
        ctxByCall[n]
      }
    }

    func joinedUserText(_ message: Message) -> String? {
      guard case let .user(u) = message else { return nil }
      return u.content.compactMap { block in
        guard case let .text(t) = block else { return nil }
        return t.text
      }.joined()
    }

    func joinedStoredText(_ message: WuhuUserMessage) -> String {
      message.content.compactMap { block in
        guard case let .text(text, _) = block else { return nil }
        return text
      }.joined()
    }

    let captures = Captures()

    let prompt1 = "What is going on in the last two commits?"
    let s1 = try await service.promptStream(
      sessionID: session.id,
      input: prompt1,
      user: "alice",
      tools: [],
      streamFn: { model, ctx, opts in
        await captures.stream(model: model, ctx: ctx, opts)
      },
    )
    for try await _ in s1 {}

    let c1 = try #require(await captures.context(forCall: 1))
    let lastUser1 = try #require(c1.messages.last(where: { $0.role == .user }))
    #expect(joinedUserText(lastUser1) == prompt1)

    let prompt2 = "Can you summarize?"
    let s2 = try await service.promptStream(
      sessionID: session.id,
      input: prompt2,
      user: "bob",
      tools: [],
      streamFn: { model, ctx, opts in
        await captures.stream(model: model, ctx: ctx, opts)
      },
    )
    for try await _ in s2 {}

    let c2 = try #require(await captures.context(forCall: 2))
    let allUser2 = c2.messages.compactMap(joinedUserText(_:))

    #expect(allUser2.contains(prompt1))
    #expect(allUser2.contains { $0.contains("A new user has joined this conversation") && $0.contains("alice") })
    #expect(allUser2.last == "bob:\n\n\(prompt2)")

    let transcriptAfter2 = try await service.getTranscript(sessionID: session.id)
    let storedUserMessages = transcriptAfter2.compactMap { entry -> WuhuUserMessage? in
      guard case let .message(m) = entry.payload else { return nil }
      guard case let .user(u) = m else { return nil }
      return u
    }
    #expect(storedUserMessages.count >= 2)
    #expect(storedUserMessages[0].user == "alice")
    #expect(joinedStoredText(storedUserMessages[0]).trimmingCharacters(in: .whitespacesAndNewlines) == prompt1)
    #expect(storedUserMessages[1].user == "bob")
    #expect(joinedStoredText(storedUserMessages[1]).trimmingCharacters(in: .whitespacesAndNewlines) == prompt2)

    let prompt3 = "Thanks."
    let s3 = try await service.promptStream(
      sessionID: session.id,
      input: prompt3,
      user: "alice",
      tools: [],
      streamFn: { model, ctx, opts in
        await captures.stream(model: model, ctx: ctx, opts)
      },
    )
    for try await _ in s3 {}

    let c3 = try #require(await captures.context(forCall: 3))
    let allUser3 = c3.messages.compactMap(joinedUserText(_:))

    #expect(allUser3.contains(prompt1))
    #expect(allUser3.contains("bob:\n\n\(prompt2)"))
    #expect(allUser3.last == "alice:\n\n\(prompt3)")
  }

  @Test func userMessageDecodingDefaultsUserForHistoricalData() throws {
    let json = #"{"content":[{"type":"text","text":"hi","signature":null}],"timestamp":0}"#
    let data = Data(json.utf8)
    let decoded = try WuhuJSON.decoder.decode(WuhuUserMessage.self, from: data)
    #expect(decoded.user == WuhuUserMessage.unknownUser)
  }
}
