import Clocks
import Fetch
import Foundation
import MachineChannel
import MachineContract
import Scratch
import SpaceCore
import SpaceServer
import Testing

#if canImport(Darwin)
  import Darwin
#else
  import Glibc
#endif

// The kill paths scripts lean on: a kill that lands before the start still
// wins, and a process stranded by a machine drop gets killed when the machine
// comes back unless a caller is still dialed to resume it.
@Suite struct MachineKillTests {
  @Test func aKillBeforeTheStartKeepsTheCommandFromRunning() async throws {
    let space = try makeMachineSpace()
    let server = TestServer(space: space, clock: TestClock())
    let (machine, key) = try await addMachine(server)
    let scratch = try ScratchFolder("kill-before-start")
    defer { scratch.remove() }
    let marker = scratch.url.appendingPathComponent("marker").path

    try await runScenario(server: server) { dialer, host in
      dialer.offer(try await connectMachine(server, key: key))
      let exec = try await mintExec(server, machine: machine)
      #expect(try await server.http(.post, "/v1/exec/\(exec.rawValue)/kill").status == .ok)
      #expect(try await space.execRecord(exec)?.terminal == .cancelled, "the kill is recorded before any frame goes out")

      host.attach(try await connectCaller(server, exec: exec))
      _ = await host.endpoint.startExec(makeExecStart(exec, command: ["sh", "-c", "echo ran > \(marker)"]))
      try await ContinuousClock().sleep(for: .milliseconds(500))
      #expect(!FileManager.default.fileExists(atPath: marker), "a start arriving after the kill must never run")
      #expect(try await space.execRecord(exec)?.terminal == .cancelled)
    }
  }

  @Test func aMachineLostExecWithNoCallerIsKilledWhenTheMachineReconnects() async throws {
    let space = try makeMachineSpace()
    let clock = TestClock()
    let server = TestServer(space: space, clock: clock)
    let (machine, key) = try await addMachine(server)

    try await runScenario(server: server) { dialer, _ in
      let machineSocket = try await connectMachine(server, key: key)
      dialer.offer(machineSocket)
      let exec = try await mintExec(server, machine: machine)
      let caller = try await connectCaller(server, exec: exec)
      let received = FrameLog()
      let reader = Task {
        for await message in caller.inbound {
          guard case let .binary(bytes) = message, let frame = try? FrameCodec.decode(bytes) else { continue }
          received.append(frame)
        }
        received.finish()
      }
      let start = makeExecStart(exec, command: ["sh", "-c", "echo $$; exec sleep 1000"])
      try await caller.send(.binary(FrameCodec.encode(Frame(streamID: 1, opcode: .execStart, payload: start))))
      let pid = try await startedPid(received)
      defer { if processAlive(pid) { _ = kill(pid, SIGKILL) } }

      machineSocket.close()
      let lost = try await realPollUntil {
        await clock.advance(by: .seconds(61))
        return try await space.execRecord(exec)?.terminal == .machineLost
      }
      #expect(lost)
      #expect(try await realPollUntil { received.finished() }, "the hub closes the caller leg with the failure")
      #expect(processAlive(pid), "a dropped connection leaves the process running on the box")

      dialer.offer(try await connectMachine(server, key: key))
      let died = try await realPollUntil { !processAlive(pid) }
      #expect(died, "nobody can resume it, so the reconnect delivers its kill")
      #expect(try await space.execRecord(exec)?.killDelivered == true)
      reader.cancel()
    }
  }

  @Test func aDialedCallerKeepsAMachineLostExecAliveUntilItLeaves() async throws {
    let space = try makeMachineSpace()
    let clock = TestClock()
    let server = TestServer(space: space, clock: clock)
    let (machine, key) = try await addMachine(server)

    try await runScenario(server: server) { dialer, _ in
      let machineSocket = try await connectMachine(server, key: key)
      dialer.offer(machineSocket)
      let exec = try await mintExec(server, machine: machine)
      let firstCaller = try await connectCaller(server, exec: exec)
      let received = FrameLog()
      let reader = Task {
        for await message in firstCaller.inbound {
          guard case let .binary(bytes) = message, let frame = try? FrameCodec.decode(bytes) else { continue }
          received.append(frame)
        }
        received.finish()
      }
      let start = makeExecStart(exec, command: ["sh", "-c", "echo $$; exec sleep 1000"])
      try await firstCaller.send(.binary(FrameCodec.encode(Frame(streamID: 1, opcode: .execStart, payload: start))))
      let pid = try await startedPid(received)
      defer { if processAlive(pid) { _ = kill(pid, SIGKILL) } }

      machineSocket.close()
      let lost = try await realPollUntil {
        await clock.advance(by: .seconds(61))
        return try await space.execRecord(exec)?.terminal == .machineLost
      }
      #expect(lost)
      reader.cancel()

      let secondCaller = try await connectCaller(server, exec: exec)
      dialer.offer(try await connectMachine(server, key: key))
      let attached = try await realPollUntil {
        try await server.http(.get, "/v1/machine").json([MachineStatus].self).contains { $0.attached }
      }
      #expect(attached)
      try await ContinuousClock().sleep(for: .milliseconds(300))
      #expect(processAlive(pid), "a dialed caller may still resume it, so the reconnect leaves it alone")
      #expect(try await space.execRecord(exec)?.killDelivered == false)

      secondCaller.close()
      let died = try await realPollUntil { @Sendable in
        await clock.advance(by: .seconds(61))
        return !processAlive(pid)
      }
      #expect(died, "once the caller is gone past grace, the kill goes out")
      #expect(try await space.execRecord(exec)?.killDelivered == true)
    }
  }
}

private func startedPid(_ received: FrameLog) async throws -> Int32 {
  let printed = try await realPollUntil { received.outputText().contains("\n") }
  #expect(printed)
  return try #require(Int32(received.outputText().trimmingCharacters(in: .whitespacesAndNewlines)))
}
