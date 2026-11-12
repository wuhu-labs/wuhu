import Clocks
import Dependencies
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
    let tokens = try await testTokens(space: space, spaceURL: "https://space.test:5530")
    let server = TestServer(space: space, clock: ContinuousClock(), tokens: tokens)
    let (machine, _) = try await addMachine(server)
    let sessionID = try await makeEnvironmentSession(space)
    let forged = StringMap(["WUHU_EXEC": "0", "WUHU_TOKEN": "forged", "WUHU_SPACE_URL": "https://elsewhere"])

    try await withMixedExecAgents(server, machines: [machine]) {
      try await withThrowingTaskGroup(of: Void.self) { tasks in
        let host = ChannelEndpoint()

        let record = try await space.reserveExec(machine: machine, caller: sessionID.rawValue)
        let transport = try await connectExecCaller(record.id, space: space, hub: server.hub)
        tasks.addTask { await host.run(transport) }
        defer { tasks.cancelAll() }
        let session = try await collectExec(await host.startExec(
          ExecStart(id: record.id, cwd: "/", command: Self.probe, env: forged),
        ))
        #expect(String(decoding: session.stdout, as: UTF8.self).hasPrefix("1|https://space.test:5530|***|"))
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

  @Test func theSignedExecCredentialKeepsTheExecsOriginalTimeout() async throws {
    let space = try makeMachineSpace()
    let tokens = try await testTokens(space: space, spaceURL: "https://space.test:5530")
    let server = TestServer(space: space, clock: ContinuousClock(), tokens: tokens)
    let (machine, _) = try await addMachine(server)
    let sessionID = try await makeEnvironmentSession(space)

    try await withMixedExecAgents(server, machines: [machine]) {
      let record = try await space.reserveExec(machine: machine, caller: sessionID.rawValue)
      let caller = ChannelEndpoint()
      let outgoing = await caller.startExec(.init(id: record.id, cwd: "/", command: ["sh", "-c", "echo up; exec sleep 30"], timeout: 600))
      try await withThrowingTaskGroup(of: Void.self) { tasks in
        let transport = try await connectExecCaller(record.id, space: space, hub: server.hub)
        tasks.addTask { await caller.run(transport) }
        defer { tasks.cancelAll() }
        var events = outgoing.events.makeAsyncIterator()
        _ = try await mixedExecOutput(&events, atLeast: 3)
        let request = try #require(try await space.execRequest(record.id))
        #expect(request.createdAt == record.startedAt)
        let prepared = try await withDependencies {
          $0.date = DateGenerator { record.startedAt.addingTimeInterval(120) }
        } operation: {
          try await server.hub.prepare(request, machine: machine.rawValue)
        }
        let credential = try #require(prepared.input.object?["sessionCredential"]?.object)
        let bearer = try #require(credential["token"]?.stringValue)
        #expect(bearer.hasPrefix(ExecTokens.prefix))
        let claims = try #require(try await tokens.identity.credential(String(bearer.dropFirst(ExecTokens.prefix.count))))
        #expect(claims.credential == .exec)
        #expect(claims.session == sessionID && claims.machine == machine && claims.exec == record.id)
        #expect(claims.group == record.group)
        #expect(claims.iat == Int(record.startedAt.timeIntervalSince1970))
        #expect(claims.exp == claims.iat + 600)
        #expect(credential["expiresAt"]?.intValue == claims.exp)
        try await server.hub.kill(record.id)
        _ = try await mixedExecExit(&events)
        #expect(try await space.execRecord(record.id)?.terminal == .signaled(signal: 15))
      }
    }
  }
}

private func makeEnvironmentSession(_ space: Space) async throws -> SessionDomain.SessionID {
  try await space.sessions.createSession(group: .shared, title: "exec environment", kind: .task, createdBy: "owner", executor: .kernel(.init(provider: "testing", model: "test-model", effort: "high")))
}
