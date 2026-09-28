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
}
