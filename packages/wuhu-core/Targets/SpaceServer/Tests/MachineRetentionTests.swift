import Foundation
import MachineChannel
import MachineContract
import SpaceCore
@testable import SpaceServer
import Testing

@Suite(.timeLimit(.minutes(1)))
struct MachineRetentionTests {
  @Test(arguments: [false, true])
  func terminalExecMapsDisappearWhenCallerLeaves(callerLeavesFirst: Bool) async throws {
    let space = try makeMachineSpace()
    let server = TestServer(space: space, clock: ContinuousClock())
    let (machine, key) = try await addMachine(server)
    try await runScenario(server: server) { dialer, host in
      dialer.offer(try await connectMachine(server, key: key))
      let id = try await mintExec(server, machine: machine)
      let socket = try await connectCaller(server, exec: id)
      host.attach(socket)
      let exec = await host.endpoint.startExec(makeExecStart(id, command: ["sh", "-c", "echo ready; sleep 0.2"]))
      var events = exec.events.makeAsyncIterator()
      #expect(try await events.next() != nil)
      if !callerLeavesFirst {
        while let event = try await events.next() {
          if case .exit = event { break }
        }
      }
      socket.close()
      #expect(try await realPollUntil {
        let terminal = try await space.execRecord(id)?.terminal
        let retained = await server.hub.retainsExec(id)
        return terminal != nil && !retained
      })
    }
  }
}
