import Clocks
import DeterministicDependencies
import Fetch
#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import JSONValue
import MachineChannel
import MachineContract
import Serve
import SessionDomain
import SpaceCore
@testable import SpaceServer
import Testing

@Suite(.deterministicDependencies) struct SessionExecEnvironmentTests {
  static let probe = ["sh", "-c", "printf '%s|%s|%s|%s' \"${WUHU_EXEC-unset}\" \"${WUHU_SPACE_URL-unset}\" \"${WUHU_TOKEN-unset}\" \"${#WUHU_TOKEN}\""]

  @Test func aSessionsExecRunsWithItsTokenMaskedAndAHumansWithout() async throws {
    let space = try makeMachineSpace()
    let tokens = ExecTokens(spaceURL: "https://space.test:5530")
    let server = TestServer(space: space, clock: ContinuousClock(), tokens: tokens)
    let (machine, _) = try await addMachine(server)
    let sessionID = try await makeEnvironmentSession(space)
    let forged = StringMap(["WUHU_EXEC": "0", "WUHU_TOKEN": "forged", "WUHU_SPACE_URL": "https://elsewhere"])

    try await withMixedExecAgents(server, machines: [machine]) { _ in
      try await withThrowingTaskGroup(of: Void.self) { tasks in
        let host = ChannelEndpoint()

        let record = try await space.mintExec(machine: machine, caller: sessionID.rawValue)
        await server.hub.noteMinted(record)
        let transport = try await connectExecCaller(record.id, space: space, hub: server.hub)
        tasks.addTask { await host.run(transport) }
        defer { tasks.cancelAll() }
        let session = try await collectExec(await host.startExec(
          ExecStart(id: record.id, cwd: "/", command: Self.probe, env: forged),
        ))
        #expect(String(decoding: session.stdout, as: UTF8.self) == "1|https://space.test:5530|***|68")
        #expect(session.exit == .exited(code: 0))
        #expect(try await space.execRecord(record.id)?.command.contains("wst_") == false)

        let human = try await mintExec(server, machine: machine)
        let other = ChannelEndpoint()
        let humanTransport = try await connectExecCaller(human, space: space, hub: server.hub)
        tasks.addTask { await other.run(humanTransport) }
        let plain = try await collectExec(await other.startExec(
          ExecStart(id: human, cwd: "/", command: Self.probe, env: forged),
        ))
        #expect(String(decoding: plain.stdout, as: UTF8.self) == "unset|unset|unset|0")
      }
    }
  }

  @Test func aSessionsExecGetsItsIDTokenCapabilityMaskedAndAHumansNone() async throws {
    let space = try makeMachineSpace()
    let tokens = ExecTokens(spaceURL: "https://space.test:5530")
    let server = TestServer(space: space, clock: ContinuousClock(), tokens: tokens)
    let (machine, _) = try await addMachine(server)
    let probe = ["sh", "-c", "printf '%s|%s|%s' \"${WUHU_ID_TOKEN_URL-unset}\" \"${WUHU_ID_TOKEN_REQUEST-unset}\" \"${#WUHU_ID_TOKEN_REQUEST}\""]
    let sessionID = try await makeEnvironmentSession(space)
    let forged = StringMap(["WUHU_ID_TOKEN_URL": "https://elsewhere", "WUHU_ID_TOKEN_REQUEST": "wit_forged"])

    try await withMixedExecAgents(server, machines: [machine]) { _ in
      try await withThrowingTaskGroup(of: Void.self) { tasks in
        let host = ChannelEndpoint()

        let record = try await space.mintExec(machine: machine, caller: sessionID.rawValue)
        await server.hub.noteMinted(record)
        let transport = try await connectExecCaller(record.id, space: space, hub: server.hub)
        tasks.addTask { await host.run(transport) }
        defer { tasks.cancelAll() }
        let session = try await collectExec(await host.startExec(ExecStart(id: record.id, cwd: "/", command: probe, env: forged)))
        #expect(String(decoding: session.stdout, as: UTF8.self) == "https://space.test:5530/v1/id-token|***|68")
        #expect(session.exit == .exited(code: 0))

        let human = try await mintExec(server, machine: machine)
        let other = ChannelEndpoint()
        let humanTransport = try await connectExecCaller(human, space: space, hub: server.hub)
        tasks.addTask { await other.run(humanTransport) }
        let plain = try await collectExec(await other.startExec(ExecStart(id: human, cwd: "/", command: probe, env: forged)))
        #expect(String(decoding: plain.stdout, as: UTF8.self) == "unset|unset|0")
      }
    }
  }

  @Test func theIDTokenGrantFollowsTheExecTimeoutAndEndsWithTheExec() async throws {
    let space = try makeMachineSpace()
    let tokens = ExecTokens(spaceURL: "https://space.test:5530")
    let server = TestServer(space: space, clock: ContinuousClock(), tokens: tokens)
    let (machine, _) = try await addMachine(server)
    let sessionID = try await makeEnvironmentSession(space)

    try await withMixedExecAgents(server, machines: [machine]) { _ in
      let record = try await space.mintExec(machine: machine, caller: sessionID.rawValue)
      await server.hub.noteMinted(record)
      let caller = ChannelEndpoint()
      let outgoing = await caller.startExec(.init(id: record.id, cwd: "/", command: ["sh", "-c", "echo up; exec sleep 30"], timeout: 600))
      let started = Date()
      try await withThrowingTaskGroup(of: Void.self) { tasks in
        let transport = try await connectExecCaller(record.id, space: space, hub: server.hub)
        tasks.addTask { await caller.run(transport) }
        defer { tasks.cancelAll() }
        var events = outgoing.events.makeAsyncIterator()
        _ = try await mixedExecOutput(&events, atLeast: 3)
        let expiry = try #require(tokens.idTokens.expiry(of: record.id))
        #expect(expiry >= started.addingTimeInterval(600) && expiry <= Date().addingTimeInterval(600))
        try await server.hub.kill(record.id)
        _ = try await mixedExecExit(&events)
        #expect(try await realPollUntil { tokens.idTokens.expiry(of: record.id) == nil })
        #expect(try await space.execRecord(record.id)?.terminal == .cancelled)
      }
    }
  }
}

private func makeEnvironmentSession(_ space: Space) async throws -> SessionDomain.SessionID {
  try await space.sessions.createSession(group: .shared, title: "exec environment", kind: .task, createdBy: "owner", executor: .kernel(.init(provider: "testing", model: "test-model", effort: "high")))
}
