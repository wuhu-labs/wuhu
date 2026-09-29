import enum ClaudeStream.ClaudeCode
import Clocks
import struct Credentials.CredentialResolver
import Dependencies
import Foundation
import JSONValue
@testable import LoopCore
import Scratch
import SessionDomain
import SessionTools
import SpaceCore
@testable import SpaceServer
import Testing

#if canImport(Darwin)
  import Darwin
#else
  import Glibc
#endif

// Claude Code never closes the request of a tool call it was killed in the
// middle of; the activation's end is what stops the call's work on the box.
@Suite struct ClaudeCodeCutOffTests {
  @Test func aKilledActivationsExecIsKilledOnItsMachine() async throws {
    try await withSessionDeps {
      try await withCutOffScenario { loopback, scratch in
        let session = try await loopback.claudeSession()
        let activation = UUID()
        let token = loopback.host.tokens.mint(.init(session: session, activation: activation))
        let call: JSONValue = ["jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": [
          "name": "exec",
          "arguments": ["machine": "box", "cwd": .string(scratch.path), "command": "echo $$ > pid; exec sleep 1000"],
          "_meta": ["claudecode/toolUseId": "toolu_exec"],
        ]]
        async let answer = loopback.post("/v1/session/\(session.rawValue)/mcp", call, bearer: token)
        let pid = try await startedPid(in: scratch)
        defer { if processAlive(pid) { _ = kill(pid, SIGKILL) } }

        await loopback.host.tokens.end(activation)
        let record = try await loopback.space.execRecord(caller: session.rawValue, toolCallID: ToolCallID("toolu_exec"))
        #expect(record?.killDelivered == true, "the machine got the kill before the end returned")
        #expect(try await realPollUntil { !processAlive(pid) }, "the machine's signal took the process down")
        _ = try? await answer
      }
    }
  }

  @Test func aKilledActivationsScriptIsStoppedWithItsProcesses() async throws {
    try await withSessionDeps {
      try await withCutOffScenario { loopback, scratch in
        let session = try await loopback.claudeSession()
        let activation = UUID()
        let token = loopback.host.tokens.mint(.init(session: session, activation: activation))
        let source = """
        import { machine } from "wuhu:machine"
        await machine("box").exec("echo $$ > pid; exec sleep 1000", { cwd: "\(scratch.path)" })
        """
        let call: JSONValue = ["jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": [
          "name": "run_script",
          "arguments": ["source": .string(source), "timeout_seconds": 600],
          "_meta": ["claudecode/toolUseId": "toolu_script"],
        ]]
        async let answer = loopback.post("/v1/session/\(session.rawValue)/mcp", call, bearer: token)
        let pid = try await startedPid(in: scratch)
        defer { if processAlive(pid) { _ = kill(pid, SIGKILL) } }

        let exec = try #require(try await loopback.space.liveExecs().first).id
        await loopback.host.tokens.end(activation)
        #expect(try await loopback.space.liveExecs().isEmpty, "the script ended before the end returned")
        #expect(try await loopback.space.execRecord(exec)?.killDelivered == true, "the machine got the kill")
        #expect(try await realPollUntil { !processAlive(pid) }, "the machine's signal took the process down")
        _ = try? await answer
      }
    }
  }

  @Test func anInterruptedProcessEndsOnlyOnceTheExecItWasRunningIsKilled() async throws {
    try await withSessionDeps {
      try await withCutOffScenario { loopback, scratch in
        let (ending, session) = try await claudeCodeInAnExec(loopback, scratch) { process in process.kill() }
        #expect(ending == "signal 9")
        #expect(try await loopback.space.liveExecs().isEmpty, "the exec ended before the process's run returned")
        let record = try await loopback.space.execRecord(caller: session.rawValue, toolCallID: ToolCallID("toolu_exec"))
        #expect(record?.killDelivered == true)
      }
    }
  }

  @Test func aProcessThatExitsMidCallEndsOnlyOnceTheExecItWasRunningIsKilled() async throws {
    try await withSessionDeps {
      try await withCutOffScenario { loopback, scratch in
        let (ending, session) = try await claudeCodeInAnExec(loopback, scratch) { _ in
          FileManager.default.createFile(atPath: scratch.url.appendingPathComponent("exit").path, contents: nil)
        }
        #expect(ending == "exit status 0")
        #expect(try await loopback.space.liveExecs().isEmpty, "the exec ended before the process's run returned")
        let record = try await loopback.space.execRecord(caller: session.rawValue, toolCallID: ToolCallID("toolu_exec"))
        #expect(record?.killDelivered == true)
      }
    }
  }
}

// Runs a stand-in for Claude Code through the host, sends an exec call with
// its token and, once the exec's process is up, ends it with `end`. Returns
// how the process's run said it ended.
private func claudeCodeInAnExec(
  _ loopback: ClaudeCodeLoopback,
  _ scratch: ScratchFolder,
  end: (ClaudeCodeProcess) -> Void,
) async throws -> (ending: String, session: SessionID) {
  let binary = loopback.config.url.appendingPathComponent("vendors/claude/\(ClaudeCode.version)/claude")
  try FileManager.default.createDirectory(at: binary.deletingLastPathComponent(), withIntermediateDirectories: true)
  try Data("""
  #!/bin/sh
  cp ../mcp.json '\(scratch.path)/mcp.json.part' && mv '\(scratch.path)/mcp.json.part' '\(scratch.path)/mcp.json'
  while [ ! -e '\(scratch.path)/exit' ]; do sleep 0.05; done

  """.utf8).write(to: binary)
  try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)
  loopback.host.serveLoopback(on: "http://127.0.0.1:1")

  let session = try await loopback.claudeSession()
  let launch = ClaudeCodeLaunch(session: session, activation: UUID(), log: try await loopback.space.sessions.claudeCodeLog(session))
  let process = try await loopback.host.seam.spawn(launch)
  async let ending = process.run()
  let config = scratch.url.appendingPathComponent("mcp.json")
  #expect(try await realPollUntil { FileManager.default.fileExists(atPath: config.path) }, "the process started")
  let token = try #require(try String(contentsOf: config, encoding: .utf8).firstMatch(of: #/cct_[0-9a-f]+/#)).output
  let call: JSONValue = ["jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": [
    "name": "exec",
    "arguments": ["machine": "box", "cwd": .string(scratch.path), "command": "echo $$ > pid; exec sleep 1000"],
    "_meta": ["claudecode/toolUseId": "toolu_exec"],
  ]]
  async let answer = loopback.post("/v1/session/\(session.rawValue)/mcp", call, bearer: String(token))
  let pid = try await startedPid(in: scratch)
  defer { if processAlive(pid) { _ = kill(pid, SIGKILL) } }
  end(process)
  let ended = await ending
  _ = try? await answer
  return (ended, session)
}

// A real machine agent on this host, named box, and a loopback listener whose
// tools reach it.
private func withCutOffScenario(
  _ body: @escaping @Sendable (ClaudeCodeLoopback, ScratchFolder) async throws -> Void,
) async throws {
  let space = try makeMachineSpace()
  let server = TestServer(space: space, clock: TestClock())
  let (_, key) = try await addMachine(server)
  let scratch = try ScratchFolder("cc-cut-off")
  defer { scratch.remove() }
  try await runScenario(server: server) { dialer, _ in
    dialer.offer(try await connectMachine(server, key: key))
    #expect(try await realPollUntil { await !server.hub.attachedMachines().isEmpty })
    let scripts = Scripts(
      space: space,
      machines: ScriptMachineAccess(
        files: machineSeam(hub: server.hub), exec: execBackend(space: space, hub: server.hub),
      ),
    )
    let loopback = try await ClaudeCodeLoopback(
      space: space, hub: server.hub, scripts: scripts, credentials: CredentialResolver { _ in .claudeCodeOAuth("sk-ant-oat") },
    )
    defer { loopback.config.remove() }
    try await withThrowingTaskGroup(of: Void.self) { group in
      group.addTask { await scripts.run() }
      try await body(loopback, scratch)
      group.cancelAll()
    }
  }
}

private func startedPid(in scratch: ScratchFolder) async throws -> Int32 {
  let file = scratch.url.appendingPathComponent("pid")
  let written = try await realPollUntil {
    (try? String(contentsOf: file, encoding: .utf8)).map { $0.hasSuffix("\n") } ?? false
  }
  #expect(written, "the command started on the machine")
  let text = try String(contentsOf: file, encoding: .utf8)
  return try #require(Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)))
}
