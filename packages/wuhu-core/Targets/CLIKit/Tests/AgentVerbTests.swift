@testable import CLIKit
import Dependencies
import Fetch
import Foundation
import JSONValue
import MinimalAgent
import Scratch
import Synchronization
import Testing

private actor Sink {
  var text = ""
  func append(_ text: String) { self.text += text }
}

private let key = "sk-fixture-secret"

private let request = JSONValue.object([
  "model": "offline/small",
  "provider": ["dialect": "anthropic", "baseURL": "https://offline.test", "models": ["small": ["maxInput": 8192, "maxOutput": 512, "efforts": ["low"], "defaultEffort": "low"]]],
  "credential": ["apiKey": .string(key)],
  "system": "You are a test agent.",
  "task": "Say ok.",
  "maxTurns": 2,
  "bashTimeoutSeconds": 5,
]).jsonString()

private let completeReply = [
  #"event: message_start\#ndata: {"type":"message_start","message":{"model":"small","usage":{"input_tokens":1,"output_tokens":0}}}"#,
  #"event: content_block_start\#ndata: {"type":"content_block_start","index":0,"content_block":{"type":"tool_use","id":"c","name":"complete","input":{"result":"ok"}}}"#,
  #"event: content_block_stop\#ndata: {"type":"content_block_stop","index":0}"#,
  #"event: message_delta\#ndata: {"type":"message_delta","delta":{"stop_reason":"tool_use"},"usage":{"output_tokens":1}}"#,
  #"event: message_stop\#ndata: {"type":"message_stop"}"#,
].joined(separator: "\n\n") + "\n\n"

private func agent(_ arguments: [String], stdin: String, terminal: Bool = false, environment: [String: String] = [:], reply: Response = Response(status: .ok, body: .bytes(Data(completeReply.utf8), contentType: "text/event-stream"))) async throws -> (code: Int32, stdout: String, stderr: String) {
  let scratch = try ScratchFolder("agent-verb")
  let stdout = Sink(), stderr = Sink()
  let runner = CommandRunner(
    fetch: FetchClient { _ in Response(status: .ok) },
    stdin: { stdin },
    stdout: { await stdout.append($0) },
    stderr: { await stderr.append($0) },
    stdinIsTerminal: terminal,
    environment: ["HOME": scratch.path].merging(environment) { _, new in new },
    currentDirectory: scratch.path,
    version: "0.1.0-dev.1",
  )
  let code = await withDependencies { $0.fetch = FetchClient { _ in reply } } operation: { await runner.run(arguments: ["agent"] + arguments) }
  return (code, await stdout.text, await stderr.text)
}

@Suite struct AgentVerbTests {
  @Test func parsesLogAndResumeAndRefusesBoth() throws {
    #expect(try Command.parse(["agent"]) == .agent(nil))
    #expect(try Command.parse(["agent", "--log", "run.jsonl"]) == .agent(.new("run.jsonl")))
    #expect(try Command.parse(["agent", "--resume", "run.jsonl"]) == .agent(.resume("run.jsonl")))
    #expect(throws: UsageError.self) { try Command.parse(["agent", "--log", "a", "--resume", "b"]) }
  }

  @Test func printsTheResultAsJSONWithoutAWallet() async throws {
    let run = try await agent([], stdin: request)
    #expect(run.code == 0)
    #expect(JSONValue.parse(run.stdout) == ["result": "ok"])
  }

  @Test func runsInASessionExecWhateverItsToken() async throws {
    for token in [nil, "", "not-a-token"] {
      var environment = ["WUHU_EXEC": "1", "WUHU_SPACE_URL": "https://space.invalid"]
      environment["WUHU_TOKEN"] = token
      let run = try await agent([], stdin: request, environment: environment)
      #expect(run.code == 0)
      #expect(JSONValue.parse(run.stdout) == ["result": "ok"])
    }
  }

  @Test func refusesATerminalStdin() async throws {
    let run = try await agent([], stdin: request, terminal: true)
    #expect(run.code == 64)
    #expect(run.stderr.contains("wuhu agent --help"))
  }

  @Test func failuresAreTypedOnStderrWithTheCredentialMasked() async throws {
    let invalid = try await agent([], stdin: "{}")
    #expect(invalid.code == 1)
    #expect(invalid.stderr.hasPrefix("invalidRequest:"))
    let denied = try await agent([], stdin: request, reply: Response(status: .unauthorized, body: .string(#"{"error":{"type":"permission_error","message":"key \#(key) is not allowed"}}"#)))
    #expect(denied.code == 1)
    #expect(denied.stderr.hasPrefix("inference:"))
    #expect(!denied.stderr.contains(key) && denied.stdout.isEmpty)
  }
}
