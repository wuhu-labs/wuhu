import Clocks
import Dependencies
import Fetch
import FetchWebSocket
#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import JSONValue
import Synchronization
import Testing
import WuhuAI

@Suite(.timeLimit(.minutes(1))) struct ResponsesWebSocketTests {
  private func endpoint() -> OpenAIGPTEndpoint {
    OpenAIGPTEndpoint(model: "test-model", baseURL: URL(string: "https://offline.test/v1")!, apiKey: "offline-token")
  }

  private func initial() -> Context {
    Context(systemPrompt: "test instructions", messages: [.user(UserMessage(content: [.text(TextContent(text: "start"))]))])
  }

  @Test func completedResponseEndsWithoutSocketEOFAndPreservesUsage() async throws {
    let server = ScriptedResponsesSocket(scripts: [textResponse("resp_1")])
    let session = ResponsesWebSocketSession()
    let observations = Mutex<[String]>([])
    var events: [InferenceEvent] = []
    try await withDependencies {
      $0[WebSocketConnector.self] = server.connector
      $0.fetch = FetchClient { _ in Issue.record("SSE fallback"); throw FetchError.unimplemented }
    } operation: {
      let inference = endpoint().withWebSocket(session: session, attemptID: "one", observer: .init(
        request: { number, _, _ in observations.withLock { $0.append("request-\(number)") } },
        event: { number, _ in observations.withLock { $0.append("event-\(number)") } },
      )).inference(context: initial())
      for try await event in inference.stream() { events.append(event) }
    }
    let handshake = try #require(await server.handshakes.first)
    #expect(handshake.url.absoluteString == "wss://offline.test/v1/responses")
    #expect(handshake.headers.sensitiveValues["authorization"] == "Bearer offline-token")
    #expect(handshake.headers.sensitiveValues["authorization"] != nil)
    #expect(handshake.limits.messageBytes == 16 << 20)
    let body = try #require(await server.sent.first?.object)
    #expect(body["type"]?.stringValue == "response.create")
    #expect(body["stream"] == nil && body["background"] == nil)
    #expect(body["store"] == .bool(false))
    #expect(body["previous_response_id"] == nil)
    if case let .done(message, metadata) = events.last {
      #expect(message.content == [.text(TextContent(text: "hello"))])
      #expect(metadata.usage?.inputTokens == 10)
      #expect(metadata.usage?.cacheReadTokens == 3)
      #expect(metadata.servedModel == "served-model")
    } else { Issue.record("Missing done") }
    #expect(observations.withLock { $0.first } == "request-1")
    await session.invalidate()
  }

  @Test func acknowledgementTranslatesOnlyDeltaToolResultsAndReusesConnection() async throws {
    let server = ScriptedResponsesSocket(scripts: [toolResponse("resp_1"), textResponse("resp_2")])
    let session = ResponsesWebSocketSession()
    try await withDependencies { $0[WebSocketConnector.self] = server.connector } operation: {
      let reply = try await endpoint().withWebSocket(session: session, attemptID: "one").inference(context: initial()).collect()
      var committed = reply
      if case var .toolCall(call) = committed.content[0] { call.id = "kernel call/id"; committed.content[0] = .toolCall(call) }
      var baseline = initial()
      baseline.messages.append(.assistant(committed))
      await session.acknowledge(attemptID: "one", committedMessage: committed, toolCallIDs: ["provider-call": "kernel call/id"], renderedContext: baseline)
      var next = baseline
      next.messages.append(.toolResult(ToolResultMessage(toolCallId: "kernel call/id", content: [.text(TextContent(text: "tool result"))])))
      _ = try await endpoint().withWebSocket(session: session, attemptID: "two").inference(context: next).collect()
    }
    let sent = await server.sent
    #expect(sent.count == 2)
    #expect(sent[1].object?["previous_response_id"]?.stringValue == "resp_1")
    let delta = try #require(sent[1].object?["input"]?.array)
    #expect(delta.count == 1)
    #expect(delta[0].object?["call_id"]?.stringValue == "provider-call")
    #expect(await server.handshakes.count == 1)
    await session.invalidate()
  }

  @Test(arguments: ["uncommitted", "wrong-attempt", "changed-content", "phase-loss", "changed-header", "changed-tools", "changed-options"])
  func unsafeContinuationSendsFullContext(_ reason: String) async throws {
    let phase = reason == "phase-loss" ? "commentary" : nil
    let server = ScriptedResponsesSocket(scripts: [textResponse("resp_1", phase: phase), textResponse("resp_2")])
    let session = ResponsesWebSocketSession()
    try await withDependencies { $0[WebSocketConnector.self] = server.connector } operation: {
      let reply = try await endpoint().withWebSocket(session: session, attemptID: "one").inference(context: initial()).collect()
      var committed = reply
      if reason == "changed-content" { committed.content = [.text(TextContent(text: "not the returned reply"))] }
      if reason == "phase-loss" { committed.phase = nil }
      var baseline = initial()
      baseline.messages.append(.assistant(committed))
      if reason != "uncommitted" {
        await session.acknowledge(attemptID: reason == "wrong-attempt" ? "wrong" : "one", committedMessage: committed, toolCallIDs: [:], renderedContext: baseline)
      }
      var next = baseline
      if reason == "changed-header" { next.messages[0] = .user(UserMessage(content: [.text(TextContent(text: "different rendered header"))])) }
      if reason == "changed-tools" { next.tools = [Tool(name: "tool", description: "changed", parameters: .object([:]))] }
      next.messages.append(.user(UserMessage(content: [.text(TextContent(text: "next"))])))
      var options = RequestOptions()
      if reason == "changed-options" { options.temperature = 0.4 }
      _ = try await endpoint().withWebSocket(session: session, attemptID: "two").inference(context: next, options: options).collect()
    }
    let second = try #require(await server.sent.last?.object)
    #expect(second["previous_response_id"] == nil)
    #expect((second["input"]?.array?.count ?? 0) >= 3)
    await session.invalidate()
  }

  @Test func exactlyOneCorrectiveCreateIsFullAndSeparatelyTapped() async throws {
    let miss = json(#"{"type":"error","error":{"code":"previous_response_not_found","message":"evicted"}}"#)
    let server = ScriptedResponsesSocket(scripts: [textResponse("resp_1"), [miss], textResponse("resp_2")])
    let session = ResponsesWebSocketSession()
    let requests = Mutex<[Int]>([])
    try await withDependencies { $0[WebSocketConnector.self] = server.connector } operation: {
      let reply = try await endpoint().withWebSocket(session: session, attemptID: "one").inference(context: initial()).collect()
      var baseline = initial(); baseline.messages.append(.assistant(reply))
      await session.acknowledge(attemptID: "one", committedMessage: reply, toolCallIDs: [:], renderedContext: baseline)
      baseline.messages.append(.user(UserMessage(content: [.text(TextContent(text: "next"))])))
      _ = try await endpoint().withWebSocket(session: session, attemptID: "two", observer: .init(request: { number, _, _ in requests.withLock { $0.append(number) } })).inference(context: baseline).collect()
    }
    let sent = await server.sent
    #expect(sent.count == 3)
    #expect(sent[1].object?["previous_response_id"]?.stringValue == "resp_1")
    #expect(sent[2].object?["previous_response_id"] == nil)
    #expect((sent[2].object?["input"]?.array?.count ?? 0) > (sent[1].object?["input"]?.array?.count ?? 0))
    #expect(requests.withLock { $0 } == [1, 2])
    await session.invalidate()
  }

  @Test func missWithoutPreviousIDIsTypedAndNeverRetried() async throws {
    let server = ScriptedResponsesSocket(scripts: [[json(#"{"type":"error","error":{"code":"previous_response_not_found"}}"#)]])
    let session = ResponsesWebSocketSession()
    await withDependencies { $0[WebSocketConnector.self] = server.connector } operation: {
      await #expect(throws: InferenceError.transient(status: nil, body: "previous_response_not_found")) {
        try await endpoint().withWebSocket(session: session, attemptID: "one").inference(context: initial()).collect()
      }
    }
    #expect(await server.sent.count == 1)
  }

  @Test func malformedToolArgumentsFailInsteadOfBecomingEmptyObject() async throws {
    let server = ScriptedResponsesSocket(scripts: [toolResponse("resp_1", arguments: "not json")])
    let session = ResponsesWebSocketSession()
    await withDependencies { $0[WebSocketConnector.self] = server.connector } operation: {
      do {
        _ = try await endpoint().withWebSocket(session: session, attemptID: "one").inference(context: initial()).collect()
        Issue.record("Malformed arguments committed")
      } catch {
        guard case .transient = error as? InferenceError else { Issue.record("Wrong failure: \(error)"); return }
      }
    }
  }

  @Test func incompleteMaxTokensEndsWithUsageAndStopReason() async throws {
    var script = textResponse("resp_1")
    script[script.count - 1] = json(#"{"type":"response.incomplete","response":{"id":"resp_1","status":"incomplete","incomplete_details":{"reason":"max_output_tokens"},"usage":{"input_tokens":10,"output_tokens":2}}}"#)
    let server = ScriptedResponsesSocket(scripts: [script])
    let session = ResponsesWebSocketSession()
    try await withDependencies { $0[WebSocketConnector.self] = server.connector } operation: {
      var done = false
      for try await event in endpoint().withWebSocket(session: session, attemptID: "one").inference(context: initial()).stream() {
        if case let .done(_, metadata) = event { done = true; #expect(metadata.stopReason == .maxTokens); #expect(metadata.usage?.outputTokens == 2) }
      }
      #expect(done)
    }
    await session.invalidate()
  }

  @Test func codexHeadersArePreservedAndQuotaIsTappedPerCall() async throws {
    let server = ScriptedResponsesSocket(scripts: [[json(#"{"type":"codex.rate_limits","rate_limits":{"primary":{"used_percent":10}}}"#)] + textResponse("resp_1")])
    let session = ResponsesWebSocketSession()
    let quota = Mutex(0)
    let endpoint = OpenAICodexEndpoint(model: "test-model", baseURL: URL(string: "https://offline.test/codex")!, jwt: "offline-token", chatgptAccountID: "account", sessionID: "session", originator: "test")
    try await withDependencies { $0[WebSocketConnector.self] = server.connector } operation: {
      _ = try await endpoint.withWebSocket(session: session, attemptID: "one", observer: .init(event: { _, event in
        if event.object?["type"]?.stringValue == "codex.rate_limits" { quota.withLock { $0 += 1 } }
      })).inference(context: initial()).collect()
    }
    let headers = try #require(await server.handshakes.first?.headers)
    #expect(headers["OpenAI-Beta"] == "responses_websockets=2026-02-06")
    #expect(headers["session-id"] == "session" && headers["thread-id"] == "session")
    #expect(headers["originator"] == "test" && headers.sensitiveValues["chatgpt-account-id"] == "account")
    #expect(quota.withLock { $0 } == 1)
    await session.invalidate()
  }

  @Test func interleavedParallelToolCallsRetainTheirOwnArguments() async throws {
    var script = toolResponse("resp_1")
    let second = toolResponse("resp_1", callID: "provider-call-2", itemID: "fc_2", arguments: #"{"b":2}"#)
    script.insert(second[1], at: 2)
    script.insert(second[2], at: 4)
    script.insert(second[3], at: 6)
    script.insert(second[4], at: 8)
    let server = ScriptedResponsesSocket(scripts: [script])
    let session = ResponsesWebSocketSession()
    try await withDependencies { $0[WebSocketConnector.self] = server.connector } operation: {
      let reply = try await endpoint().withWebSocket(session: session, attemptID: "one").inference(context: initial()).collect()
      let calls = reply.content.compactMap { if case let .toolCall(call) = $0 { call } else { nil } }
      #expect(calls.count == 2)
      #expect(calls[0].id == "provider-call" && calls[0].arguments.text == #"{"a":1}"#)
      #expect(calls[1].id == "provider-call-2" && calls[1].arguments.text == #"{"b":2}"#)
    }
    await session.invalidate()
  }

  @Test func cancellationAbortsAndNextAttemptReconnectsWithFullContext() async throws {
    let server = ScriptedResponsesSocket(scripts: [[], textResponse("resp_2")])
    let session = ResponsesWebSocketSession()
    let task = Task {
      try await withDependencies { $0[WebSocketConnector.self] = server.connector } operation: {
        try await endpoint().withWebSocket(session: session, attemptID: "one").inference(context: initial()).collect()
      }
    }
    await server.waitForSend(1)
    task.cancel()
    _ = await task.result
    for await _ in server.aborted.stream { break }
    #expect(server.aborts.withLock { $0 } >= 1)
    try await withDependencies { $0[WebSocketConnector.self] = server.connector } operation: {
      _ = try await endpoint().withWebSocket(session: session, attemptID: "two").inference(context: initial()).collect()
    }
    #expect(await server.handshakes.count == 2)
    #expect(await server.sent.last?.object?["previous_response_id"] == nil)
    await session.invalidate()
  }

  @Test func oneInferenceAtATimeIsEnforced() async throws {
    let server = ScriptedResponsesSocket(scripts: [[]])
    let session = ResponsesWebSocketSession()
    let task = Task {
      try await withDependencies { $0[WebSocketConnector.self] = server.connector } operation: {
        try await endpoint().withWebSocket(session: session, attemptID: "one").inference(context: initial()).collect()
      }
    }
    await server.waitForSend(1)
    await withDependencies { $0[WebSocketConnector.self] = server.connector } operation: {
      await #expect(throws: InferenceError.invalidInput(status: 409, body: "A Responses inference is already active")) {
        try await endpoint().withWebSocket(session: session, attemptID: "two").inference(context: initial()).collect()
      }
    }
    task.cancel(); _ = await task.result
    #expect(await server.sent.count == 1)
  }

  @Test func EOFBeforeTerminalIsConnectionClosedNotSuccess() async throws {
    let server = ScriptedResponsesSocket(scripts: [[]])
    let session = ResponsesWebSocketSession()
    let task = Task {
      try await withDependencies { $0[WebSocketConnector.self] = server.connector } operation: {
        try await endpoint().withWebSocket(session: session, attemptID: "one").inference(context: initial()).collect()
      }
    }
    await server.waitForSend(1)
    await server.disconnect()
    switch await task.result {
    case .success: Issue.record("EOF succeeded")
    case .failure(let error): #expect(error as? InferenceError == .transport(.connectionClosed))
    }
  }

  @Test func secondMissIsNotRetriedAndMidstreamMissNeverRegenerates() async throws {
    let miss = json(#"{"type":"error","error":{"code":"previous_response_not_found"}}"#)
    for midstream in [false, true] {
      var events = Array(textResponse("resp_2").prefix(3))
      events.append(miss)
      let server = ScriptedResponsesSocket(scripts: [textResponse("resp_1"), midstream ? events : [miss], [miss]])
      let session = ResponsesWebSocketSession()
      try await withDependencies { $0[WebSocketConnector.self] = server.connector } operation: {
        let reply = try await endpoint().withWebSocket(session: session, attemptID: "one").inference(context: initial()).collect()
        var context = initial(); context.messages.append(.assistant(reply))
        await session.acknowledge(attemptID: "one", committedMessage: reply, toolCallIDs: [:], renderedContext: context)
        context.messages.append(.user(UserMessage(content: [.text(TextContent(text: "next"))])))
        await #expect(throws: InferenceError.transient(status: nil, body: "previous_response_not_found")) {
          try await endpoint().withWebSocket(session: session, attemptID: "two").inference(context: context).collect()
        }
      }
      #expect(await server.sent.count == (midstream ? 2 : 3))
    }
  }

  @Test(arguments: [401, 403, 429, 500]) func refusedUpgradeHasExplicitClassification(_ status: Int) async throws {
    let session = ResponsesWebSocketSession()
    await withDependencies {
      $0[WebSocketConnector.self] = WebSocketConnector { _ in throw WebSocketError.refused(status: status, headers: .init(), body: Array("refused".utf8)) }
    } operation: {
      do {
        _ = try await endpoint().withWebSocket(session: session, attemptID: "one").inference(context: initial()).collect()
        Issue.record("Refused upgrade succeeded")
      } catch {
        let error = error as? InferenceError
        switch status {
        case 401, 403: #expect(error == .invalidInput(status: status, body: "refused"))
        case 429: #expect(error == .rateLimited(retryAt: nil))
        case 500: #expect(error == .transient(status: 500, body: "refused"))
        default: Issue.record("Unexpected test status")
        }
      }
    }
  }

  @Test func credentialChangeRotatesSocketAndDoesNotReusePreviousID() async throws {
    let server = ScriptedResponsesSocket(scripts: [textResponse("resp_1"), textResponse("resp_2")])
    let session = ResponsesWebSocketSession()
    try await withDependencies { $0[WebSocketConnector.self] = server.connector } operation: {
      let reply = try await endpoint().withWebSocket(session: session, attemptID: "one").inference(context: initial()).collect()
      var context = initial(); context.messages.append(.assistant(reply))
      await session.acknowledge(attemptID: "one", committedMessage: reply, toolCallIDs: [:], renderedContext: context)
      context.messages.append(.user(UserMessage(content: [.text(TextContent(text: "next"))])))
      var changed = endpoint(); changed.apiKey = "different-offline-token"
      _ = try await changed.withWebSocket(session: session, attemptID: "two").inference(context: context).collect()
    }
    #expect(await server.handshakes.count == 2)
    #expect(await server.sent.last?.object?["previous_response_id"] == nil)
    await session.invalidate()
  }

  @Test func boundedConnectionExpiryRecoveryRedialsOnceWithFullContext() async throws {
    let expiry = json(#"{"type":"error","status_code":400,"error":{"code":"websocket_connection_limit_reached"}}"#)
    let server = ScriptedResponsesSocket(scripts: [[expiry], textResponse("resp_2")])
    let session = ResponsesWebSocketSession()
    try await withDependencies { $0[WebSocketConnector.self] = server.connector } operation: {
      _ = try await endpoint().withWebSocket(session: session, attemptID: "one").inference(context: initial()).collect()
    }
    #expect(await server.handshakes.count == 2)
    #expect(await server.sent.count == 2)
    #expect(await server.sent.last?.object?["previous_response_id"] == nil)
    await session.invalidate()
  }

  @Test(arguments: [
    #"{"type":"error","status_code":429,"error":{"message":"limited","headers":{"retry-after":"60"}}}"#,
    #"{"type":"error","error":{"code":"usage_limit_reached","message":"limited","headers":{"retry-after":"60"}}}"#,
  ])
  func statusCodeAndNestedRetryHeadersAreClassified(_ frame: String) async throws {
    let server = ScriptedResponsesSocket(scripts: [[json(frame)]])
    let session = ResponsesWebSocketSession()
    let now = Date(timeIntervalSince1970: 1_792_567_680)
    await withDependencies {
      $0[WebSocketConnector.self] = server.connector
      $0.date = .constant(now)
    } operation: {
      do {
        _ = try await endpoint().withWebSocket(session: session, attemptID: "one").inference(context: initial()).collect()
        Issue.record("Rate limit succeeded")
      } catch {
        #expect(error as? InferenceError == .rateLimited(retryAt: now.addingTimeInterval(60)))
      }
    }
  }

  @Test(arguments: ["binary", "bad-json", "missing-usage", "missing-id", "unfinished-tool", "unknown-incomplete", "cancelled"])
  func malformedStreamsCannotCommit(_ kind: String) async throws {
    var script = textResponse("resp_1")
    switch kind {
    case "binary": script = [.message(.binary([1, 2]))]
    case "bad-json": script = [json("{")]
    case "missing-usage": script[script.count - 1] = json(#"{"type":"response.completed","response":{"id":"resp_1","status":"completed"}}"#)
    case "missing-id": script = [json(#"{"type":"response.completed","response":{"status":"completed","usage":{}}}"#)]
    case "unfinished-tool": script = Array(toolResponse("resp_1").prefix(3)) + [textResponse("resp_1").last!]
    case "unknown-incomplete": script[script.count - 1] = json(#"{"type":"response.incomplete","response":{"id":"resp_1","incomplete_details":{"reason":"unknown"},"usage":{}}}"#)
    case "cancelled": script = [json(#"{"type":"response.cancelled","response":{"id":"resp_1"}}"#)]
    default: break
    }
    let server = ScriptedResponsesSocket(scripts: [script])
    let session = ResponsesWebSocketSession()
    await withDependencies { $0[WebSocketConnector.self] = server.connector } operation: {
      do {
        _ = try await endpoint().withWebSocket(session: session, attemptID: "one").inference(context: initial()).collect()
        Issue.record("Malformed stream committed")
      } catch { guard case .transient = error as? InferenceError else { Issue.record("Wrong error: \(error)"); return } }
    }
  }

  @Test(arguments: ["before-ack", "after-ack", "remote"])
  func changedOrUnverifiableMediaProjectionCannotContinue(_ kind: String) async throws {
    let server = ScriptedResponsesSocket(scripts: [textResponse("resp_1"), textResponse("resp_2")])
    let session = ResponsesWebSocketSession()
    let resolver = MutableSocketMedia()
    var context = initial()
    context.messages.append(.user(UserMessage(content: [.media(MediaContent(url: URL(string: kind == "remote" ? "https://offline.test/image.png" : "media://owned/image")!, mimeType: "image/png"))])))
    try await withDependencies { $0[WebSocketConnector.self] = server.connector } operation: {
      let reply = try await endpoint().withWebSocket(session: session, attemptID: "one").inference(context: context, mediaResolver: resolver).collect()
      context.messages.append(.assistant(reply))
      if kind == "before-ack" { await resolver.change() }
      await session.acknowledge(attemptID: "one", committedMessage: reply, toolCallIDs: [:], renderedContext: context)
      if kind == "after-ack" { await resolver.change() }
      context.messages.append(.user(UserMessage(content: [.text(TextContent(text: "next"))])))
      _ = try await endpoint().withWebSocket(session: session, attemptID: "two").inference(context: context, mediaResolver: resolver).collect()
    }
    #expect(await server.sent.last?.object?["previous_response_id"] == nil)
    await session.invalidate()
  }

  @Test func idleTimeoutUsesInjectedClockAndInvalidatesTheSocket() async throws {
    let server = ScriptedResponsesSocket(scripts: [[]])
    let session = ResponsesWebSocketSession()
    let clock = TestClock()
    let task = Task {
      try await withDependencies {
        $0[WebSocketConnector.self] = server.connector
        $0.continuousClock = clock
      } operation: {
        var options = RequestOptions(); options.idleTimeout = .seconds(1)
        return try await endpoint().withWebSocket(session: session, attemptID: "one").inference(context: initial(), options: options).collect()
      }
    }
    await server.waitForSend(1)
    await clock.advance(by: .seconds(3))
    switch await task.result {
    case .success: Issue.record("Idle turn succeeded")
    case .failure(let error): #expect(error as? InferenceError == .transport(.idleTimeout))
    }
    #expect(server.aborts.withLock { $0 } >= 1)
  }

  @Test func finalOutputItemTextSurvivesEmptyTerminalOutputWithoutDeltas() async throws {
    var script = textResponse("resp_1")
    script.remove(at: 2)
    script[2] = json(#"{"type":"response.output_item.done","item":{"type":"message","id":"msg_1","content":[{"type":"output_text","text":"authoritative final text"}]}}"#)
    let server = ScriptedResponsesSocket(scripts: [script])
    let session = ResponsesWebSocketSession()
    try await withDependencies { $0[WebSocketConnector.self] = server.connector } operation: {
      let reply = try await endpoint().withWebSocket(session: session, attemptID: "one").inference(context: initial()).collect()
      #expect(reply.content == [.text(TextContent(text: "authoritative final text"))])
    }
    await session.invalidate()
  }

  @Test(arguments: [false, true])
  func streamedRefusalAndFilteredIncompletePreserveText(filtered: Bool) async throws {
    let script = [
      json(#"{"type":"response.created","response":{"id":"resp_refusal"}}"#),
      json(#"{"type":"response.output_item.added","item":{"id":"msg_refusal","type":"message","role":"assistant","content":[]}}"#),
      json(#"{"type":"response.refusal.delta","item_id":"msg_refusal","delta":"Cannot "}"#),
      json(#"{"type":"response.refusal.delta","item_id":"msg_refusal","delta":"help."}"#),
      json(#"{"type":"response.output_item.done","item":{"id":"msg_refusal","type":"message","role":"assistant","content":[{"type":"refusal","refusal":"Cannot help."}]}}"#),
      filtered ? json(#"{"type":"response.incomplete","response":{"id":"resp_refusal","status":"incomplete","incomplete_details":{"reason":"content_filter"},"usage":{"input_tokens":3,"output_tokens":2},"output":[]}}"#) : json(#"{"type":"response.completed","response":{"id":"resp_refusal","status":"completed","usage":{"input_tokens":3,"output_tokens":2},"output":[]}}"#),
    ]
    let server = ScriptedResponsesSocket(scripts: [script, textResponse("resp_after")])
    let session = ResponsesWebSocketSession()
    try await withDependencies { $0[WebSocketConnector.self] = server.connector } operation: {
      var done: AssistantMessage?
      var metadata: AssistantMessageMetadata?
      for await result in endpoint().withWebSocket(session: session, attemptID: "refusal").runInference(context: initial(), options: .init(), mediaResolver: nil) {
        switch result {
        case .success(.done(let message, let result)): done = message; metadata = result
        case .failure(let error): throw error
        default: break
        }
      }
      let message = try #require(done)
      #expect(message.content == [.text("Cannot help.")])
      #expect(metadata?.stopReason == (filtered ? .refusal : .stop))
      #expect(metadata?.usage?.inputTokens == 3)
      var context = initial()
      context.messages.append(.assistant(message))
      await session.acknowledge(attemptID: "refusal", committedMessage: message, toolCallIDs: [:], renderedContext: context)
      context.messages.append(.user(.init(content: [.text("again")])))
      _ = try await endpoint().withWebSocket(session: session, attemptID: "next").inference(context: context).collect()
    }
    if filtered { #expect(await server.sent.last?.object?["previous_response_id"] == nil) }
    await session.invalidate()
  }

  @Test func suspendedFinishedRawTapCannotDropQuotaOrMutateTheNextTurn() async throws {
    let gate = CallbackSuspension()
    let server = ScriptedResponsesSocket(scripts: [textResponse("resp_1") + [json(#"{"type":"codex.rate_limits"}"#)], textResponse("resp_2")])
    let session = ResponsesWebSocketSession()
    try await withDependencies { $0[WebSocketConnector.self] = server.connector } operation: {
      let first = Task {
        try await endpoint().withWebSocket(session: session, attemptID: "one", observer: .init(received: { _, message in
          if case .text(let text) = message, JSONValue.parse(text)?.object?["type"]?.stringValue == "codex.rate_limits" { await gate.suspendOnce() }
        })).inference(context: initial()).collect()
      }
      for await _ in gate.entered.stream { break }
      _ = try await first.value
      let second = Task {
        try await endpoint().withWebSocket(session: session, attemptID: "two", receiveQuota: { _ in await server.recordQuota() }).inference(context: initial()).collect()
      }
      await server.waitForSend(2)
      gate.release.continuation.yield(())
      _ = try await second.value
      #expect(await server.quotaReceipts == 1)
    }
    #expect(await server.handshakes.count == 1)
    await session.invalidate()
  }

  @Test func idleQuotaHasSessionReceiverButNeverLeaksIntoFinishedAttemptTap() async throws {
    let server = ScriptedResponsesSocket(scripts: [textResponse("resp_1"), textResponse("resp_2")])
    let session = ResponsesWebSocketSession()
    let tapped = Mutex(0)
    let quota = AsyncStream<JSONValue>.makeStream()
    try await withDependencies { $0[WebSocketConnector.self] = server.connector } operation: {
      _ = try await endpoint().withWebSocket(session: session, attemptID: "one", observer: .init(event: { _, _ in tapped.withLock { $0 += 1 } }), receiveQuota: { quota.continuation.yield($0) }).inference(context: initial()).collect()
      let event = #"{"type":"codex.rate_limits","rate_limits":{"primary":{"used_percent":10,"window_minutes":300,"reset_at":1800000300}}}"#
      await server.emit(json(event))
      var iterator = quota.stream.makeAsyncIterator()
      #expect(await iterator.next() == JSONValue.parse(event))
      #expect(tapped.withLock { $0 } == 5)
      _ = try await endpoint().withWebSocket(session: session, attemptID: "two").inference(context: initial()).collect()
      #expect(tapped.withLock { $0 } == 5)
    }
    #expect(await server.handshakes.count == 1)
    await session.invalidate()
  }

  @Test func reusedSocketReplacesPerCallObserverInsteadOfLoggingIntoFirstAttempt() async throws {
    let server = ScriptedResponsesSocket(scripts: [textResponse("resp_1"), textResponse("resp_2")])
    let session = ResponsesWebSocketSession()
    let first = Mutex(0), second = Mutex(0)
    try await withDependencies { $0[WebSocketConnector.self] = server.connector } operation: {
      _ = try await endpoint().withWebSocket(session: session, attemptID: "one", observer: .init(event: { _, _ in first.withLock { $0 += 1 } })).inference(context: initial()).collect()
      #expect(first.withLock { $0 } == 5)
      _ = try await endpoint().withWebSocket(session: session, attemptID: "two", observer: .init(event: { _, _ in second.withLock { $0 += 1 } })).inference(context: initial()).collect()
      #expect(first.withLock { $0 } == 5 && second.withLock { $0 } == 5)
    }
    #expect(await server.handshakes.count == 1)
    await session.invalidate()
  }
}

private func json(_ text: String) -> WebSocketEvent { .message(.text(text)) }

private func textResponse(_ id: String, phase: String? = nil) -> [WebSocketEvent] {
  let phaseField = phase.map { ",\"phase\":\"\($0)\"" } ?? ""
  return [
    json("{\"type\":\"response.created\",\"response\":{\"id\":\"\(id)\"}}"),
    json("{\"type\":\"response.output_item.added\",\"item\":{\"type\":\"message\",\"id\":\"msg_1\"\(phaseField)}}"),
    json(#"{"type":"response.output_text.delta","item_id":"msg_1","delta":"hello"}"#),
    json("{\"type\":\"response.output_item.done\",\"item\":{\"type\":\"message\",\"id\":\"msg_1\"\(phaseField)}}"),
    json("{\"type\":\"response.completed\",\"response\":{\"id\":\"\(id)\",\"status\":\"completed\",\"model\":\"served-model\",\"output\":[],\"usage\":{\"input_tokens\":10,\"output_tokens\":2,\"input_tokens_details\":{\"cached_tokens\":3}}}}"),
  ]
}

private func toolResponse(_ id: String, callID: String = "provider-call", itemID: String = "fc_1", arguments: String = #"{"a":1}"#) -> [WebSocketEvent] {
  let args = JSONValue.string(arguments).jsonString()
  return [
    json("{\"type\":\"response.created\",\"response\":{\"id\":\"\(id)\"}}"),
    json("{\"type\":\"response.output_item.added\",\"item\":{\"type\":\"function_call\",\"id\":\"\(itemID)\",\"call_id\":\"\(callID)\",\"name\":\"test\",\"arguments\":\"\"}}"),
    json("{\"type\":\"response.function_call_arguments.delta\",\"item_id\":\"\(itemID)\",\"delta\":\(args)}"),
    json("{\"type\":\"response.function_call_arguments.done\",\"item_id\":\"\(itemID)\",\"arguments\":\(args)}"),
    json("{\"type\":\"response.output_item.done\",\"item\":{\"type\":\"function_call\",\"id\":\"\(itemID)\",\"call_id\":\"\(callID)\",\"name\":\"test\",\"arguments\":\(args)}}"),
    json("{\"type\":\"response.completed\",\"response\":{\"id\":\"\(id)\",\"status\":\"completed\",\"output\":[],\"usage\":{\"input_tokens\":10,\"output_tokens\":2}}}"),
  ]
}

private actor ScriptedResponsesSocket {
  var scripts: [[WebSocketEvent]]
  private let ending: String?
  var quotaReceipts = 0
  func recordQuota() { quotaReceipts += 1 }
  var sent: [JSONValue] = []
  var handshakes: [WebSocketRequest] = []
  nonisolated let counts = AsyncStream<Int>.makeStream()
  nonisolated let aborts = Mutex(0)
  nonisolated let aborted = AsyncStream<Void>.makeStream()
  private var connections: [AsyncThrowingStream<WebSocketEvent, any Error>.Continuation] = []

  func disconnect() { connections.last?.finish() }
  func emit(_ event: WebSocketEvent) { connections.last?.yield(event) }

  func waitForSend(_ count: Int) async {
    if sent.count >= count { return }
    for await current in counts.stream { if current >= count { return } }
  }

  init(scripts: [[WebSocketEvent]], ending: String? = nil) { self.scripts = scripts; self.ending = ending }

  nonisolated var connector: WebSocketConnector { WebSocketConnector { try await self.connect($0) } }

  func connect(_ request: WebSocketRequest) throws -> WebSocketConnection {
    handshakes.append(request)
    let events = AsyncThrowingStream<WebSocketEvent, any Error>.makeStream()
    connections.append(events.continuation)
    return WebSocketConnection(inbound: WebSocketInbound(events.stream), send: { message in
      try await self.send(message, into: events.continuation)
    }, close: { close in events.continuation.yield(.closed(close)); events.continuation.finish() }, abort: { self.aborts.withLock { $0 += 1 }; self.aborted.continuation.yield(()); events.continuation.finish() })
  }

  func send(_ message: WebSocketMessage, into events: AsyncThrowingStream<WebSocketEvent, any Error>.Continuation) throws {
    guard case let .text(text) = message, let value = JSONValue.parse(text), !scripts.isEmpty else { throw WebSocketError.protocolViolation("Unexpected send") }
    sent.append(value)
    counts.continuation.yield(sent.count)
    for event in scripts.removeFirst() { events.yield(event) }
    if ending == "close" { events.yield(.closed(.init(code: 1000))) }
    if ending != nil { events.finish(throwing: ending == "io" ? WebSocketError.io("offline reset") : nil) }
  }
}

private actor MutableSocketMedia: MediaResolver {
  var data = Data([1])
  func change() { data = Data([2]) }
  func resolve(_ media: MediaContent) async throws -> ResolvedMedia? {
    media.url.scheme == "media" ? .data(data, mimeType: "image/png") : .url(media.url, mimeType: "image/png")
  }
}

@Suite(.timeLimit(.minutes(1))) struct ResponsesCompletionAndCallbackTests {
  private func endpoint() -> OpenAIGPTEndpoint {
    OpenAIGPTEndpoint(model: "test-model", baseURL: URL(string: "https://offline.test/v1")!, apiKey: "offline-token")
  }

  private func initial() -> Context {
    Context(messages: [.user(UserMessage(content: [.text(TextContent(text: "start"))]))])
  }

  @Test(arguments: Array(0 ..< 10)) func completedThenCloseMustStaySuccessful(_ iteration: Int) async throws {
    let server = ScriptedResponsesSocket(scripts: [textResponse("resp_1") + [.closed(.init(code: 1000, reason: "done"))]])
    let session = ResponsesWebSocketSession()
    try await withDependencies { $0[WebSocketConnector.self] = server.connector } operation: {
      let reply = try await endpoint().withWebSocket(session: session, attemptID: "one").inference(context: initial()).collect()
      #expect(reply.content == [.text(TextContent(text: "hello"))])
    }
    await session.invalidate()
  }

  @Test(arguments: ["eof", "io", "close"])
  func teardownAfterTerminalCannotRetractCompletionOrReuseItsContinuation(ending: String) async throws {
    let server = ScriptedResponsesSocket(scripts: [textResponse("resp_1"), textResponse("resp_2")], ending: ending)
    let session = ResponsesWebSocketSession()
    try await withDependencies { $0[WebSocketConnector.self] = server.connector } operation: {
      var context = initial()
      let completed = try await endpoint().withWebSocket(session: session, attemptID: "one").inference(context: context).collect()
      context.messages.append(.assistant(completed))
      await session.acknowledge(attemptID: "one", committedMessage: completed, toolCallIDs: [:], renderedContext: context)
      context.messages.append(.user(.init(content: [.text("again")])))
      _ = try await endpoint().withWebSocket(session: session, attemptID: "two").inference(context: context).collect()
    }
    #expect(await server.handshakes.count == 2)
    #expect(await server.sent.last?.object?["previous_response_id"] == nil)
    #expect(await server.sent.last?.object?["input"]?.array?.count == 3)
    await session.invalidate()
  }

  @Test(arguments: ["upgrade-header", "metadata-header", "request-observer", "event-observer", "quota"])
  func cancellationWhileCallbackSuspendsFinishesAndNextInferenceIsFresh(stage: String) async throws {
    let gate = CallbackSuspension()
    let metadata = json(#"{"type":"codex.response.metadata","headers":{"x-suspend":"metadata"}}"#)
    let scripts = stage == "metadata-header" ? [[metadata] + textResponse("resp_1"), textResponse("resp_2")] : (stage == "quota" ? [[json(#"{"type":"codex.rate_limits"}"#)] + textResponse("resp_1"), textResponse("resp_2")] : [textResponse("resp_1"), textResponse("resp_2")])
    let server = ScriptedResponsesSocket(scripts: scripts)
    let session = ResponsesWebSocketSession()
    let endpoint = OpenAICodexEndpoint(model: "test-model", baseURL: URL(string: "https://offline.test/codex")!, jwt: "offline", sessionID: "one", receiveResponseHeaders: { headers in
      if stage == "upgrade-header" || (stage == "metadata-header" && headers["x-suspend"] == "metadata") { await gate.suspendOnce() }
    })
    try await withDependencies { $0[WebSocketConnector.self] = server.connector } operation: {
      let first = Task {
        try await endpoint.withWebSocket(session: session, attemptID: "one", observer: .init(request: { _, _, _ in
          if stage == "request-observer" { await gate.suspendOnce() }
        }, event: { _, _ in
          if stage == "event-observer" { await gate.suspendOnce() }
        }), receiveQuota: { _ in
          if stage == "quota" { await gate.suspendOnce() }
        }).inference(context: initial()).collect()
      }
      for await _ in gate.entered.stream { break }
      first.cancel()
      switch await first.result {
      case .success: Issue.record("cancelled callback produced success")
      case .failure(let error): #expect(error as? InferenceError == .cancelled)
      }
      for await _ in gate.finished.stream { break }
      for await _ in server.aborted.stream { break }
      _ = try await endpoint.withWebSocket(session: session, attemptID: "two").inference(context: initial()).collect()
    }
    #expect(await server.handshakes.count == 2)
    #expect(await server.sent.last?.object?["previous_response_id"] == nil)
    await session.invalidate()
  }

  @Test(arguments: [false, true])
  func suspendedPostTerminalCallbackCannotOverwriteNewInference(headers: Bool) async throws {
    let quotaEntered = AsyncStream<Void>.makeStream()
    let releaseQuota = AsyncStream<Void>.makeStream()
    let postTerminal = headers ? json(#"{"type":"codex.response.metadata","headers":{"x-suspend":"metadata"}}"#) : json(#"{"type":"codex.rate_limits"}"#)
    let server = ScriptedResponsesSocket(scripts: [textResponse("resp_1") + [postTerminal], textResponse("resp_2")])
    let endpoint = OpenAICodexEndpoint(model: "test-model", baseURL: URL(string: "https://offline.test/codex")!, jwt: "offline", sessionID: "one", receiveResponseHeaders: { fields in
      if headers && fields["x-suspend"] == "metadata" {
        quotaEntered.continuation.yield(())
        for await _ in releaseQuota.stream { break }
      }
    })
    let session = ResponsesWebSocketSession()
    try await withDependencies { $0[WebSocketConnector.self] = server.connector } operation: {
      let first = Task {
        try await endpoint.withWebSocket(session: session, attemptID: "one", observer: .init(event: { _, event in
          if event.object?["type"]?.stringValue == "codex.rate_limits" {
            quotaEntered.continuation.yield(())
            for await _ in releaseQuota.stream { break }
          }
        })).inference(context: initial()).collect()
      }
      for await _ in quotaEntered.stream { break }
      _ = try await first.value
      let second = Task { try await endpoint.withWebSocket(session: session, attemptID: "two").inference(context: initial()).collect() }
      await server.waitForSend(2)
      releaseQuota.continuation.yield(())
      _ = try await second.value
    }
    await session.invalidate()
  }
}

private final class CallbackSuspension: Sendable {
  private let used = Mutex(false)
  let entered = AsyncStream<Void>.makeStream()
  let finished = AsyncStream<Void>.makeStream()
  let release = AsyncStream<Void>.makeStream()

  func suspendOnce() async {
    guard used.withLock({ used in if used { return false }; used = true; return true }) else { return }
    entered.continuation.yield(())
    for await _ in release.stream { break }
    finished.continuation.yield(())
  }
}
