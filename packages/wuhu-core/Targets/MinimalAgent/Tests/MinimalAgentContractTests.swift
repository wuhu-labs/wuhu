import CProcessIdentity
import Dependencies
import Fetch
import Foundation
import JSONValue
import MinimalAgent
import Scratch
import Synchronization
import Testing
import WuhuAI

private let key = "sk-fixture-secret"
private let token = "session-token-fixture"

private func request(task: String = "Do the task.", maxTurns: Int = 8, bashTimeoutSeconds: Int = 30, model: String = "offline/small", apiKey: String = key) -> String {
  let document: JSONValue = [
    "model": .string(model),
    "provider": ["dialect": "anthropic", "baseURL": "https://offline.test", "models": ["small": ["maxInput": 8192, "maxOutput": 512, "efforts": ["low"], "defaultEffort": "low"]]],
    "credential": ["apiKey": .string(apiKey)],
    "system": "You are a test agent.",
    "task": .string(task),
    "maxTurns": .integer(maxTurns),
    "bashTimeoutSeconds": .integer(bashTimeoutSeconds),
  ]
  return document.jsonString()
}

private typealias Block = (start: String, delta: String?)

private func sse(_ blocks: [Block]) -> String {
  var events = [#"event: message_start\#ndata: {"type":"message_start","message":{"model":"small","usage":{"input_tokens":10,"output_tokens":0}}}"#]
  for (index, block) in blocks.enumerated() {
    events.append(#"event: content_block_start\#ndata: {"type":"content_block_start","index":\#(index),"content_block":\#(block.start)}"#)
    if let delta = block.delta {
      events.append(#"event: content_block_delta\#ndata: {"type":"content_block_delta","index":\#(index),"delta":\#(delta)}"#)
    }
    events.append(#"event: content_block_stop\#ndata: {"type":"content_block_stop","index":\#(index)}"#)
  }
  events.append(#"event: message_delta\#ndata: {"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":5}}"#)
  events.append(#"event: message_stop\#ndata: {"type":"message_stop"}"#)
  return events.joined(separator: "\n\n") + "\n\n"
}

private func call(_ id: String, _ name: String, _ input: JSONValue) -> Block {
  (JSONValue.object(["type": "tool_use", "id": .string(id), "name": .string(name), "input": input]).jsonString(), nil)
}

private func text(_ text: String) -> Block {
  (#"{"type":"text","text":""}"#, JSONValue.object(["type": "text_delta", "text": .string(text)]).jsonString())
}

/// Replays one scripted reply per model call and records every request it was sent.
private final class FakeModel: Sendable {
  let replies: Mutex<[Response]>
  let requests = Mutex<[(apiKey: String?, body: JSONValue)]>([])

  init(_ replies: [[Block]]) {
    self.replies = Mutex(replies.map { Response(status: .ok, body: .bytes(Data(sse($0).utf8), contentType: "text/event-stream")) })
  }

  init(failing status: Status, body: String) {
    replies = Mutex([Response(status: status, body: .string(body))])
  }

  var fetch: FetchClient {
    FetchClient { request in
      let body = JSONValue.parse(String(decoding: try await request.body?.data() ?? Data(), as: UTF8.self)) ?? .null
      self.requests.withLock { $0.append((request.headers.sensitiveValues["x-api-key"], body)) }
      guard let reply = self.replies.withLock({ $0.isEmpty ? nil : $0.removeFirst() }) else {
        Issue.record("model called past its script")
        return Response(status: .internalServerError)
      }
      return reply
    }
  }

  var bodies: [JSONValue] { requests.withLock { $0.map(\.body) } }
}

private func run(_ model: FakeModel, _ text: String, log: AgentLog? = nil, in folder: ScratchFolder) async throws(AgentError) -> String {
  do {
    return try await withDependencies {
      $0.fetch = model.fetch
      $0.continuousClock = ContinuousClock()
    } operation: {
      try await MinimalAgent.run(request: text, log: log, workingDirectory: folder.path)
    }
  } catch {
    throw error as! AgentError
  }
}

private func failure(_ body: () async throws(AgentError) -> String) async -> AgentError? {
  do { _ = try await body(); return nil } catch { return error }
}

private func toolResults(_ body: JSONValue) -> [String] {
  (body.object?["messages"]?.array ?? []).flatMap { message in
    (message.object?["content"]?.array ?? []).compactMap { block -> String? in
      guard block.object?["type"]?.stringValue == "tool_result" else { return nil }
      return block.object?["content"]?.jsonString()
    }
  }
}

/// Every string value in a JSON document, descending into strings that hold JSON themselves (tool-call arguments).
private func strings(_ value: JSONValue) -> [String] {
  switch value {
  case let .string(text):
    if let inner = JSONValue.parse(text), inner.object != nil || inner.array != nil { return [text] + strings(inner) }
    return [text]
  case let .array(items): return items.flatMap(strings)
  case let .object(fields): return fields.values.flatMap(strings)
  default: return []
  }
}

@Suite struct MinimalAgentContractTests {
  @Test func toolLoopWritesReadsRunsBashAndCompletes() async throws {
    let folder = try ScratchFolder("minimal-agent")
    let model = FakeModel([
      [call("w", "write", ["path": "notes/a.txt", "content": "hello agent"])],
      [call("r", "read", ["path": "notes/a.txt"])],
      [call("b", "bash", ["command": "wc -c < notes/a.txt; echo oops >&2; exit 3"])],
      [text("Done."), call("c", "complete", ["result": "wrote and checked notes/a.txt"])],
    ])
    let result = try await run(model, request(), log: .new("run.jsonl"), in: folder)
    #expect(result == "wrote and checked notes/a.txt")
    #expect(try String(contentsOf: folder.url.appending(path: "notes/a.txt"), encoding: .utf8) == "hello agent")

    let requests = model.requests.withLock { $0 }
    #expect(requests.count == 4)
    for request in requests {
      #expect(request.apiKey == key)
      #expect(request.body.object?["model"] == "small")
      #expect(request.body.object?["max_tokens"] == 512)
      #expect(request.body.object?["tools"]?.array?.compactMap { $0.object?["name"]?.stringValue } == ["read", "write", "bash", "complete"])
      #expect(request.body.jsonString().contains("You are a test agent."))
    }
    let results = toolResults(requests[3].body)
    #expect(results.count == 3)
    #expect(results[0].contains("wrote 11 bytes to notes/a.txt"))
    #expect(results[1].contains("hello agent"))
    #expect(results[2].contains("exit 3"))
    #expect(results[2].contains("11"))
    #expect(results[2].contains("oops"))

    let lines = try String(contentsOf: folder.url.appending(path: "run.jsonl"), encoding: .utf8).split(separator: "\n")
    let messages = try lines.map { try JSONDecoder().decode(Message.self, from: Data($0.utf8)) }
    #expect(messages.count == 9)
    #expect(messages.first?.user != nil)
    #expect(messages.last?.toolResult?.toolCallId == "c")
    #expect(!lines.joined().contains(key))
  }

  @Test func aReplyWithoutToolCallsGetsOneReminderThenNoComplete() async throws {
    let folder = try ScratchFolder("minimal-agent")
    let model = FakeModel([[text("I think it is done.")], [text("Really done.")]])
    let error = await failure { () async throws(AgentError) in try await run(model, request(), in: folder) }
    #expect(error?.code == .noComplete)
    #expect(model.bodies.count == 2)
    #expect(model.bodies[1].jsonString().contains("call complete with your result"))
  }

  @Test func theReminderResetsAfterAToolCall() async throws {
    let folder = try ScratchFolder("minimal-agent")
    let model = FakeModel([[text("thinking")], [call("b", "bash", ["command": "true"])], [text("still thinking")], [call("c", "complete", ["result": "ok"])]])
    #expect(try await run(model, request(), in: folder) == "ok")
  }

  @Test func theTurnBudgetEndsTheRunTyped() async throws {
    let folder = try ScratchFolder("minimal-agent")
    let model = FakeModel([[call("1", "bash", ["command": "true"])], [call("2", "bash", ["command": "true"])]])
    let error = await failure { () async throws(AgentError) in try await run(model, request(maxTurns: 2), in: folder) }
    #expect(error?.code == .turnBudgetExhausted)
    #expect(model.bodies.count == 2)
  }

  @Test func completeWithoutAResultIsAToolErrorAndOtherCallsBesideCompleteDoNotRun() async throws {
    let folder = try ScratchFolder("minimal-agent")
    let model = FakeModel([
      [call("bad", "complete", [:])],
      [call("b", "bash", ["command": "touch ran"]), call("c", "complete", ["result": "finished"])],
    ])
    #expect(try await run(model, request(), log: .new("run.jsonl"), in: folder) == "finished")
    #expect(toolResults(model.bodies[1]).first?.contains("complete needs a string") == true)
    #expect(!FileManager.default.fileExists(atPath: folder.url.appending(path: "ran").path))
    let log = try String(contentsOf: folder.url.appending(path: "run.jsonl"), encoding: .utf8)
    #expect(log.contains("not run: complete ends the run"))
  }

  @Test func resumeContinuesTheTranscriptAndNeverReRunsAnInterruptedCall() async throws {
    let folder = try ScratchFolder("minimal-agent")
    let interrupted: [Message] = [
      .user(UserMessage(content: [.text("Do the task.")])),
      .assistant(AssistantMessage(content: [.toolCall(ToolCall(id: "t1", name: "bash", arguments: ToolArguments(["command": "touch ran"])))])),
    ]
    let path = folder.url.appending(path: "run.jsonl")
    try interrupted.map { String(decoding: try JSONEncoder().encode($0), as: UTF8.self) + "\n" }.joined().write(to: path, atomically: true, encoding: .utf8)

    let model = FakeModel([[call("c", "complete", ["result": "resumed"])]])
    #expect(try await run(model, request(task: "Continue."), log: .resume("run.jsonl"), in: folder) == "resumed")
    #expect(!FileManager.default.fileExists(atPath: folder.url.appending(path: "ran").path))
    let body = model.bodies[0].jsonString()
    #expect(body.contains("interrupted: the agent stopped before this call returned"))
    #expect(body.contains("Continue."))
    let lines = try String(contentsOf: path, encoding: .utf8).split(separator: "\n")
    #expect(lines.count == 6)
  }

  @Test func transcriptsAreNeverClobberedOrInvented() async throws {
    let folder = try ScratchFolder("minimal-agent")
    try "".write(to: folder.url.appending(path: "old.jsonl"), atomically: true, encoding: .utf8)
    try "not json\n".write(to: folder.url.appending(path: "broken.jsonl"), atomically: true, encoding: .utf8)
    try FileManager.default.createSymbolicLink(atPath: folder.url.appending(path: "link.jsonl").path, withDestinationPath: folder.url.appending(path: "elsewhere.jsonl").path)
    for log in [AgentLog.new("old.jsonl"), .new("link.jsonl"), .resume("absent.jsonl"), .resume("broken.jsonl")] {
      let error = await failure { () async throws(AgentError) in try await run(FakeModel([]), request(), log: log, in: folder) }
      #expect(error?.code == .transcript)
    }
    #expect(!FileManager.default.fileExists(atPath: folder.url.appending(path: "elsewhere.jsonl").path))
  }

  @Test func theCredentialNeverLeavesTheAgentAndNeverReachesTheShell() async throws {
    let folder = try ScratchFolder("minimal-agent")
    setenv("WUHU_TOKEN", token, 1)
    setenv("MINIMAL_AGENT_FIXTURE_KEY", "prefix-\(key)", 1)
    let model = FakeModel([
      [text("The key is \(key)."), call("b", "bash", ["command": .string("echo token=${WUHU_TOKEN:-unset} env=${MINIMAL_AGENT_FIXTURE_KEY:-unset} literal=\(key)")])],
      [call("c", "complete", ["result": .string("done with \(key)")])],
    ])
    let result = try await run(model, request(task: "Use \(key) carefully."), log: .new("run.jsonl"), in: folder)
    #expect(result == "done with ***")
    let results = toolResults(model.bodies[1])
    #expect(results.first?.contains("token=unset env=unset literal=***") == true)
    #expect(!model.bodies[1].jsonString().contains(key))
    #expect(!(try String(contentsOf: folder.url.appending(path: "run.jsonl"), encoding: .utf8)).contains(key))
  }

  @Test(arguments: [#"sk-"quoted\escaped"#, "content"])
  func maskingSeesThroughEscapingAndNeverTouchesFieldNames(secret: String) async throws {
    let folder = try ScratchFolder("minimal-agent")
    try secret.write(to: folder.url.appending(path: "secret.out"), atomically: true, encoding: .utf8)
    let model = FakeModel([
      [text("The key is \(secret)."), call("b", "bash", ["command": .string("cat secret.out; echo; echo '\(secret)'")])],
      [call("c", "complete", ["result": .string("done with \(secret)")])],
    ])
    let result = try await run(model, request(task: "Use \(secret) carefully.", apiKey: secret), log: .new("run.jsonl"), in: folder)
    #expect(result == "done with ***")
    #expect(toolResults(model.bodies[1]).first?.contains("exit 0") == true)
    let lines = try String(contentsOf: folder.url.appending(path: "run.jsonl"), encoding: .utf8).split(separator: "\n")
    let messages = try lines.map { try JSONDecoder().decode(Message.self, from: Data($0.utf8)) }
    #expect(messages.count == 5)
    let logged = lines.flatMap { strings(JSONValue.parse(String($0)) ?? .null) }
    let sent = strings(model.bodies[1].object?["messages"] ?? .null)
    #expect(!(logged + sent).contains { $0.contains(secret) })
    #expect(logged.filter { $0.contains("***") }.count >= 4)
  }

  #if os(Linux)
    @Test func theShellReadsAnAncestorsEnvironmentOnlyMaskedAndNeverTheAgents() async throws {
      let folder = try ScratchFolder("minimal-agent")
      setenv("WUHU_TOKEN", token, 1)
      // Stands in for the session exec above the agent: a process whose environment holds the token and the key.
      let ancestor = #"exec env WUHU_TOKEN=\#(token) AGENT_FIXTURE_KEY=\#(key) bash -c 'bash -c '\''tr "\0" "\n" < /proc/$PPID/environ'\''; true'"#
      try ancestor.write(to: folder.url.appending(path: "ancestor.sh"), atomically: true, encoding: .utf8)
      let model = FakeModel([
        [call("a", "bash", ["command": "bash ancestor.sh"]), call("p", "bash", ["command": "tr '\\0' '\\n' < /proc/$PPID/environ"])],
        [call("c", "complete", ["result": "ok"])],
      ])
      #expect(try await run(model, request(), in: folder) == "ok")
      #expect(process_is_dumpable() == 0)
      let results = toolResults(model.bodies[1])
      #expect(results[0].contains("WUHU_TOKEN=***"))
      #expect(results[0].contains("AGENT_FIXTURE_KEY=***"))
      #expect(results[1].contains("Permission denied"))
      #expect(!model.bodies[1].jsonString().contains(token))
      #expect(!model.bodies[1].jsonString().contains(key))
    }
  #endif

  @Test func bashIsBoundedByTheTimeoutAndTheOutputCap() async throws {
    let folder = try ScratchFolder("minimal-agent")
    let model = FakeModel([
      [call("slow", "bash", ["command": "echo started; sleep 30 & sleep 30"])],
      [call("loud", "bash", ["command": "head -c 200000 /dev/zero | tr '\\0' a; echo END"])],
      [call("c", "complete", ["result": "ok"])],
    ])
    let started = ContinuousClock.now
    #expect(try await run(model, request(bashTimeoutSeconds: 1), in: folder) == "ok")
    #expect(ContinuousClock.now - started < .seconds(20))
    let results = toolResults(model.bodies[2])
    #expect(results[0].contains("timed out after 1s; killed"))
    #expect(results[0].contains("started"))
    #expect(results[1].contains("bytes omitted"))
    #expect(results[1].contains("END"))
    #expect(results[1].utf8.count < 40000)
  }

  @Test(arguments: [
    "not json",
    #"{"model":"offline/small"}"#,
    request(maxTurns: 0),
    request(bashTimeoutSeconds: 0),
    request(model: "offline"),
    request(model: "offline/absent"),
  ])
  func badStdinIsATypedErrorBeforeAnyModelCall(text: String) async throws {
    let folder = try ScratchFolder("minimal-agent")
    let model = FakeModel([])
    let error = await failure { () async throws(AgentError) in try await run(model, text, in: folder) }
    #expect(error?.code == .invalidRequest)
    #expect(model.bodies.isEmpty)
  }

  @Test func providerErrorsAreTypedAndNeverCarryTheCredential() async throws {
    let folder = try ScratchFolder("minimal-agent")
    let model = FakeModel(failing: .unauthorized, body: #"{"error":{"type":"permission_error","message":"key \#(key) is not allowed"}}"#)
    let error = await failure { () async throws(AgentError) in try await run(model, request(), in: folder) }
    #expect(error?.code == .inference)
    #expect(error?.description.contains(key) == false)
    #expect(error?.description.contains("***") == true)
  }
}
