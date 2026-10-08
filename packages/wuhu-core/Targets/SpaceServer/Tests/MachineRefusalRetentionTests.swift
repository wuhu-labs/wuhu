import Clocks
import Foundation
import MachineChannel
import MachineContract
@testable import SpaceServer
import Testing

@Suite(.timeLimit(.minutes(1)))
struct MachineRefusalRetentionTests {
  @Test(arguments: [false, true])
  func refusedExecReplaysAfterCallerCrashUntilTerminalAckOrTenMinutes(acknowledge: Bool) async throws {
    let clock = TestClock()
    try await withSecretServer(clock: clock) { rig in
      let machine = try await rig.addMachine("refused")
      let first = EndpointHost()
      try await withThrowingTaskGroup(of: Void.self) { group in
        group.addTask { await rig.server.run() }
        group.addTask { await first.run() }
        let machineSocket = try await connectMachine(rig.server, key: machine.key)
        try await awaitAttached(rig.server, machine.id)
        let id = try await mintExec(rig.server, machine: machine.id)
        let firstSocket = try await connectCaller(rig.server, exec: id)
        first.attach(firstSocket)
        let start = rig.start(id, command: ["true"])
        let outgoing = await first.endpoint.startExec(start, autoAcknowledge: false)
        let initial = try await collectExec(outgoing)
        #expect(initial.exit == .exited(code: 127))
        #expect(String(decoding: initial.stderr, as: UTF8.self) == "wuhu: no secret API_KEY in group shared\n")
        firstSocket.close()
        #expect(try await realPollUntil { first.completedRounds == 1 })
        await clock.advance(by: .seconds(599))
        #expect(await rig.server.hub.retainsExec(id))

        let fresh = EndpointHost()
        group.addTask { await fresh.run() }
        let retrySocket = try await connectCaller(rig.server, exec: id)
        fresh.attach(retrySocket)
        let retry = await fresh.endpoint.startExec(start, autoAcknowledge: false)
        let replayed = try await collectExec(retry)
        #expect(replayed.stderr == initial.stderr)
        #expect(replayed.exit == initial.exit)
        if acknowledge { await retry.acknowledgeExit() }
        retrySocket.close()
        #expect(try await realPollUntil { fresh.completedRounds == 1 })
        if !acknowledge { await clock.advance(by: .seconds(1)) }
        #expect(try await realPollUntil { !(await rig.server.hub.retainsExec(id)) })
        machineSocket.close()
        group.cancelAll()
      }
    }
  }
}
