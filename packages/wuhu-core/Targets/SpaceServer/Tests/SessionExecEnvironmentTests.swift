import Clocks
import Fetch
import Foundation
import JSONValue
import MachineChannel
import MachineContract
import Serve
import SpaceCore
@testable import SpaceServer
import Testing

// The hub hands a session's exec its credential on the way to a real agent;
// a human's exec gets none, and nobody can plant the names themselves.
@Suite struct SessionExecEnvironmentTests {
  static let probe = ["sh", "-c", "printf '%s|%s|%s|%s' \"${WUHU_EXEC-unset}\" \"${WUHU_SPACE_URL-unset}\" \"${WUHU_TOKEN-unset}\" \"${#WUHU_TOKEN}\""]

  @Test func aSessionsExecRunsWithItsTokenMaskedAndAHumansWithout() async throws {
    let space = try makeMachineSpace()
    let tokens = ExecTokens(spaceURL: "https://space.test:5530")
    let server = TestServer(space: space, clock: ContinuousClock(), tokens: tokens)
    let (machine, key) = try await addMachine(server)
    let forged = StringMap(["WUHU_EXEC": "0", "WUHU_TOKEN": "forged", "WUHU_SPACE_URL": "https://elsewhere"])

    try await runScenario(server: server) { dialer, host in
      dialer.offer(try await connectMachine(server, key: key))

      let record = try await space.mintExec(machine: machine, caller: "orchestrator")
      await server.hub.noteMinted(record)
      host.attach(try await connectCaller(server, exec: record.id))
      let session = try await collectExec(await host.endpoint.startExec(
        ExecStart(id: record.id, cwd: "/", command: Self.probe, env: forged),
      ))
      #expect(String(decoding: session.stdout, as: UTF8.self) == "1|https://space.test:5530|***|68")
      #expect(session.exit == .exited(code: 0))
      #expect(try await space.execRecord(record.id)?.command.contains("wst_") == false)

      let human = try await mintExec(server, machine: machine)
      let other = EndpointHost()
      Task { await other.run() }
      other.attach(try await connectCaller(server, exec: human))
      let plain = try await collectExec(await other.endpoint.startExec(
        ExecStart(id: human, cwd: "/", command: Self.probe, env: forged),
      ))
      #expect(String(decoding: plain.stdout, as: UTF8.self) == "unset|unset|unset|0")
    }
  }

  // The id-token pair rides in env and the masked secret values, so it reaches
  // agents of any version; a caller's own values never pass.
  @Test func aSessionsExecGetsItsIDTokenCapabilityMaskedAndAHumansNone() async throws {
    let space = try makeMachineSpace()
    let tokens = ExecTokens(spaceURL: "https://space.test:5530")
    let server = TestServer(space: space, clock: ContinuousClock(), tokens: tokens)
    let (machine, key) = try await addMachine(server)
    let probe = ["sh", "-c", "printf '%s|%s|%s' \"${WUHU_ID_TOKEN_URL-unset}\" \"${WUHU_ID_TOKEN_REQUEST-unset}\" \"${#WUHU_ID_TOKEN_REQUEST}\""]
    let forged = StringMap(["WUHU_ID_TOKEN_URL": "https://elsewhere", "WUHU_ID_TOKEN_REQUEST": "wit_forged"])

    try await runScenario(server: server) { dialer, host in
      dialer.offer(try await connectMachine(server, key: key))

      let record = try await space.mintExec(machine: machine, caller: "orchestrator")
      await server.hub.noteMinted(record)
      host.attach(try await connectCaller(server, exec: record.id))
      let session = try await collectExec(await host.endpoint.startExec(ExecStart(id: record.id, cwd: "/", command: probe, env: forged)))
      #expect(String(decoding: session.stdout, as: UTF8.self) == "https://space.test:5530/v1/id-token|***|68")
      #expect(session.exit == .exited(code: 0))

      let human = try await mintExec(server, machine: machine)
      let other = EndpointHost()
      Task { await other.run() }
      other.attach(try await connectCaller(server, exec: human))
      let plain = try await collectExec(await other.endpoint.startExec(ExecStart(id: human, cwd: "/", command: probe, env: forged)))
      #expect(String(decoding: plain.stdout, as: UTF8.self) == "unset|unset|0")
    }
  }

  // The grant lives for the exec's own timeout, and losing the machine ends
  // it even though a v1 exec may resume when the machine returns.
  @Test func theIDTokenGrantFollowsTheExecTimeoutAndEndsWithTheMachine() async throws {
    let space = try makeMachineSpace()
    let clock = TestClock()
    let tokens = ExecTokens(spaceURL: "https://space.test:5530")
    let server = TestServer(space: space, clock: clock, tokens: tokens)
    let (machine, key) = try await addMachine(server)

    try await runScenario(server: server) { dialer, host in
      let machineSocket = try await connectMachine(server, key: key)
      dialer.offer(machineSocket)
      let record = try await space.mintExec(machine: machine, caller: "orchestrator")
      await server.hub.noteMinted(record)
      host.attach(try await connectCaller(server, exec: record.id))
      let started = Date()
      let start = ExecStart(id: record.id, cwd: "/", command: ["sh", "-c", "echo up; exec sleep 30"], env: nil, secrets: nil, window: nil, maxOutput: nil, timeout: 600)
      let outgoing = await host.endpoint.startExec(start)
      for try await event in outgoing.events {
        if case .output(.stdout, _, _) = event { break }
      }
      let expiry = try #require(tokens.idTokens.expiry(of: record.id))
      #expect(expiry >= started.addingTimeInterval(600) && expiry <= Date().addingTimeInterval(600))

      machineSocket.close()
      let revoked = try await realPollUntil {
        await clock.advance(by: .seconds(61))
        let terminal = try await space.execRecord(record.id)?.terminal
        return tokens.idTokens.expiry(of: record.id) == nil && terminal == .machineLost
      }
      #expect(revoked, "machine loss must end the id-token grant")
    }
  }
}
