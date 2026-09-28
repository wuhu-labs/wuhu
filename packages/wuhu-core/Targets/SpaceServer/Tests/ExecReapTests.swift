import Clocks
import Foundation
import MachineChannel
import MachineContract
import struct SessionDomain.ToolCallID
import SpaceCore
import SpaceServer
import Testing

// The reap contract, end to end through the hub with a scripted machine at the
// channel seam: a caller absent past the rejoin deadline gets its process
// reaped by policy, the machine buffers output to termination, and a retry
// that rejoins by the same kernel tool call id drains the tail and reads the
// honest reap verdict — never a fabricated success or a silent respawn.
@Suite struct ExecReapTests {
  @Test func reapPastGraceIsHonestAndTheBufferedTailDrains() async throws {
    let space = try makeMachineSpace()
    let clock = TestClock()
    let server = TestServer(space: space, clock: clock)
    let (machineID, key) = try await addMachine(server)
    let session = "aaaaaaaa-0000-0000-0000-000000000001"
    let early = Array("early\n".utf8)
    let late = Array("late\n".utf8)

    let machine = ChannelEndpoint()
    try await withThrowingTaskGroup(of: Void.self) { group in
      group.addTask { await server.run() }
      group.addTask {
        await machine.run(WebSocketTransport(try await connectMachine(server, key: key)))
      }
      group.addTask {
        for await exec in machine.incomingExecs {
          try? await exec.send(.stdout, early)
          var kills = exec.kills.makeAsyncIterator()
          _ = await kills.next()
          try? await exec.send(.stdout, late)
          await exec.exit(.signaled(signal: 9))
        }
      }
      group.addTask {
        _ = try await realPollUntil {
          await server.hub.attachedMachines().contains(machineID)
        }

        let claim = try await space.claimExec(machine: machineID, caller: session, toolCallID: ToolCallID("tc-exec-1"))
        #expect(claim.rejoined == false)
        await server.hub.noteMinted(claim.record)

        let firstSocket = try await connectCaller(server, exec: claim.record.id)
        let firstCaller = ChannelEndpoint()
        let exec = await firstCaller.startExec(
          makeExecStart(claim.record.id, command: ["fake"]),
          autoAcknowledge: false,
        )
        let firstRun = Task { await firstCaller.run(WebSocketTransport(firstSocket)) }

        var iterator = exec.events.makeAsyncIterator()
        var consumed: [UInt8] = []
        while consumed.count < early.count {
          guard let event = try await iterator.next() else { break }
          if case let .output(_, _, data) = event {
            consumed += data.bytes
          }
        }
        #expect(consumed == early)
        await exec.acknowledge(through: early.count)

        firstSocket.close()
        firstRun.cancel()
        let reaped = try await realPollUntil {
          await clock.advance(by: .seconds(61))
          return try await space.execRecord(claim.record.id)?.terminal == .reaped
        }
        #expect(reaped, "a caller absent past the rejoin deadline must get the exec reaped")

        let killDelivered = try await realPollUntil {
          try await space.execRecord(claim.record.id)?.killDelivered == true
        }
        #expect(killDelivered, "the reap must deliver the kill to the machine")

        let retry = try await space.claimExec(machine: machineID, caller: session, toolCallID: ToolCallID("tc-exec-1"))
        #expect(retry.rejoined == true)
        #expect(retry.record.id == claim.record.id)
        #expect(retry.record.terminal == .reaped)

        let secondSocket = try await connectCaller(server, exec: claim.record.id)
        let secondCaller = ChannelEndpoint()
        let rejoined = await secondCaller.startExec(
          makeExecStart(claim.record.id, command: ["fake"]),
          resumingFrom: early.count,
        )
        let secondRun = Task { await secondCaller.run(WebSocketTransport(secondSocket)) }

        var tail: [UInt8] = []
        var exit: MachineContract.ExitStatus?
        for try await event in rejoined.events {
          switch event {
          case let .output(_, _, data):
            tail += data.bytes
          case let .exit(status):
            exit = status
          default:
            break
          }
          if exit != nil { break }
        }
        #expect(tail == late, "the buffered tail past the last ack must drain byte-exactly")
        #expect(exit == .signaled(signal: 9))
        #expect(try await space.execRecord(claim.record.id)?.terminal == .reaped, "the real exit never overwrites the reap verdict")
        secondRun.cancel()
      }
      _ = try await group.next()
      group.cancelAll()
    }
  }
}
