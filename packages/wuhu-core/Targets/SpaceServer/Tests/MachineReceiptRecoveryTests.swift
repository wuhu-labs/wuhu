import Foundation
import MachineContract
import Scratch
import SessionDomain
import SessionTools
@testable import SpaceCore
@testable import SpaceServer
import Testing
import struct WuhuAI.ToolCall

@Suite(.timeLimit(.minutes(1)))
struct MachineReceiptRecoveryTests {
  @Test func serverRestartAfterRealAgentExitBeforeReceiptReplaysEveryByteWithoutRespawning() async throws {
    let fixture = try ScratchFolder("post-exit-receipt")
    defer { fixture.remove() }
    let file = fixture.url.appendingPathComponent("space.sqlite")
    let space = try makeMachineSpace(file: file)
    let server = TestServer(space: space, clock: ContinuousClock())
    let (machine, key) = try await addMachine(server)
    let agent = makeAgent(state: fixture)
    let dialer = AgentDialer()
    let session = try await space.sessions.createSession(
      group: .shared, title: "receipt recovery", kind: .agent, createdBy: "morgan",
      model: .init(provider: "deepseek", model: "deepseek-v4-pro", effort: "high"),
    )
    let payload = String(repeating: "post-exit replay\n", count: 100)
    let call = ToolCall(id: "post-exit", name: "exec", arguments: .object([
      "machine": .string(machine.rawValue), "cwd": .string(fixture.path),
      "command": .string("echo run >> invocations; printf '%s' '\(payload)'"),
    ]))
    try await space.writer.write { db in
      try db.execute(sql: "CREATE TRIGGER fail_exec_receipt BEFORE INSERT ON session_receipts WHEN NEW.tool_call_id = 'post-exit' BEGIN SELECT RAISE(FAIL, 'injected receipt failure'); END")
    }
    try await withThrowingTaskGroup(of: Void.self) { lifetime in
      lifetime.addTask { await agent.run(dial: dialer.dial) }
      defer { lifetime.cancelAll() }
      try await withThrowingTaskGroup(of: Void.self) { incarnation in
        incarnation.addTask { await server.run() }
        defer { incarnation.cancelAll() }
        let socket = try await connectMachine(server, key: key)
        defer { socket.close() }
        dialer.offer(socket)
        try await awaitAttached(server, machine)
        let first = ToolExecutor(space: space, machines: machineSeam(hub: server.hub), exec: execBackend(space: space, hub: server.hub))
        let failed = try await first.execute(session: session, call: call, state: ToolExecutionState())
        guard case let .failure(failure) = failed else { throw UnexpectedReceiptResult() }
        #expect(failure.message.contains("injected receipt failure"))
        #expect(try await space.sessions.receipt(session, toolCallID: .init("post-exit")) == nil)
        let claim = try await space.claimExec(machine: machine, caller: session.rawValue, toolCallID: .init("post-exit"))
        #expect(claim.record.terminal == .exited(code: 0))
      }

      let reopened = try makeMachineSpace(file: file)
      try await reopened.writer.write { db in try db.execute(sql: "DROP TRIGGER fail_exec_receipt") }
      let replacement = TestServer(space: reopened, clock: ContinuousClock())
      try await withThrowingTaskGroup(of: Void.self) { incarnation in
        incarnation.addTask { await replacement.run() }
        defer { incarnation.cancelAll() }
        dialer.offer(try await connectMachine(replacement, key: key))
        try await awaitAttached(replacement, machine)
        let fresh = ToolExecutor(space: reopened, machines: machineSeam(hub: replacement.hub), exec: execBackend(space: reopened, hub: replacement.hub))
        let recovered = try await fresh.execute(session: session, call: call, state: ToolExecutionState())
        guard case let .exec(result) = recovered else { throw UnexpectedReceiptResult() }
        #expect(result.output == payload)
        #expect(result.exitCode == 0)
        #expect(try await reopened.sessions.receipt(session, toolCallID: .init("post-exit")) == recovered)
        #expect(try String(contentsOfFile: fixture.path + "/invocations", encoding: .utf8) == "run\n")
      }
    }
  }
}

private struct UnexpectedReceiptResult: Error {}
