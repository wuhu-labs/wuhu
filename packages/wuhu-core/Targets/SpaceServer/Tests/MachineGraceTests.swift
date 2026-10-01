import Clocks
import Fetch
import Foundation
import JSONValue
import MachineChannel
import MachineContract
import Scratch
import Serve
import SpaceCore
import SpaceServer
import Synchronization
import Testing

#if canImport(Darwin)
  import Darwin
#else
  import Glibc
#endif

@Suite struct MachineGraceTests {
  @Test func callerGonePastGraceKillsTheGroupOnTheMachine() async throws {
    let space = try makeMachineSpace()
    let clock = TestClock()
    let server = TestServer(space: space, clock: clock)
    let (machine, key) = try await addMachine(server)

    try await runScenario(server: server) { dialer, host in
      dialer.offer(try await connectMachine(server, key: key))
      let exec = try await mintExec(server, machine: machine)
      let callerSocket = try await connectCaller(server, exec: exec)
      host.attach(callerSocket)

      let outgoing = await host.endpoint.startExec(makeExecStart(exec, command: ["sh", "-c", "echo $$; exec sleep 1000"]))
      var pidText = ""
      for try await event in outgoing.events {
        if case let .output(.stdout, _, data) = event {
          pidText += String(decoding: data.bytes, as: UTF8.self)
          if pidText.contains("\n") { break }
        }
      }
      let pid = try #require(Int32(pidText.trimmingCharacters(in: .whitespacesAndNewlines)))
      #expect(processAlive(pid))

      callerSocket.close()
      let died = try await realPollUntil { @Sendable in
        await clock.advance(by: .seconds(1))
        return !processAlive(pid)
      }
      #expect(died, "caller gone past grace must kill the process group")

      let settled = try await realPollUntil {
        try await space.execRecord(exec)?.terminal != nil
      }
      #expect(settled)
    }
  }

  @Test func mintedButNeverDrivenExecExpiresAndKillDeliversOnConnect() async throws {
    let space = try makeMachineSpace()
    let clock = TestClock()
    let server = TestServer(space: space, clock: clock)
    let (machine, key) = try await addMachine(server)

    try await runScenario(server: server) { dialer, _ in
      let exec = try await mintExec(server, machine: machine)
      let reaped = try await realPollUntil {
        await clock.advance(by: .seconds(61))
        return try await space.execRecord(exec)?.terminal == .reaped
      }
      #expect(reaped)
      #expect(try #require(try await space.execRecord(exec)).killDelivered == false)

      dialer.offer(try await connectMachine(server, key: key))
      let delivered = try await realPollUntil {
        try await space.execRecord(exec)?.killDelivered == true
      }
      #expect(delivered, "a pending kill must deliver on the machine's next connect")
    }
  }

  @Test func machineThatNeverDialsFailsAConnectedCallerAfterGrace() async throws {
    let space = try makeMachineSpace()
    let clock = TestClock()
    let server = TestServer(space: space, clock: clock)
    let (machine, _) = try await addMachine(server)

    try await withThrowingTaskGroup(of: Void.self) { group in
      group.addTask { await server.run() }
      group.addTask {
        let exec = try await mintExec(server, machine: machine)
        let callerSocket = try await connectCaller(server, exec: exec)
        let received = FrameLog()
        let reader = Task {
          for await message in callerSocket.inbound {
            guard case let .binary(bytes) = message, let frame = try? FrameCodec.decode(bytes) else { continue }
            received.append(frame)
          }
          received.finish()
        }
        let start = makeExecStart(exec, command: ["true"])
        try await callerSocket.send(.binary(FrameCodec.encode(Frame(streamID: 1, opcode: .execStart, payload: start))))

        let lost = try await realPollUntil {
          await clock.advance(by: .seconds(61))
          return received.machineLost()
        }
        #expect(lost, "a machine that never dialed in must fail the caller after one grace")
        let closed = try await realPollUntil { received.finished() }
        #expect(closed)
        #expect(try await space.execRecord(exec)?.terminal == .machineLost)
        reader.cancel()
      }
      _ = try await group.next()
      group.cancelAll()
    }
  }

  @Test func freshCallerAfterMachineExpiryStillFailsAfterAnotherGrace() async throws {
    let space = try makeMachineSpace()
    let clock = TestClock()
    let server = TestServer(space: space, clock: clock)
    let (machine, key) = try await addMachine(server)
    let state = try ScratchFolder("m4-agent")
    defer { state.remove() }
    let agent = makeAgent(state: state)
    let dialer = AgentDialer()

    try await withThrowingTaskGroup(of: Void.self) { group in
      group.addTask { await server.run() }
      group.addTask { await agent.run(dial: dialer.dial) }
      group.addTask {
        let machineSocket = try await connectMachine(server, key: key)
        dialer.offer(machineSocket)

        machineSocket.close()
        _ = try await realPollUntil {
          await clock.advance(by: .seconds(61))
          let attached = try await server.http(.get, "/v1/machine").json([MachineStatus].self)
          return attached.allSatisfy { !$0.attached }
        }

        // Minted after the machine's own expiry already fired: only the
        // caller-bind arming can cover this exec.
        let exec = try await mintExec(server, machine: machine)
        let callerSocket = try await connectCaller(server, exec: exec)
        let received = FrameLog()
        let reader = Task {
          for await message in callerSocket.inbound {
            guard case let .binary(bytes) = message, let frame = try? FrameCodec.decode(bytes) else { continue }
            received.append(frame)
          }
          received.finish()
        }
        let start = makeExecStart(exec, command: ["true"])
        try await callerSocket.send(.binary(FrameCodec.encode(Frame(streamID: 1, opcode: .execStart, payload: start))))

        let lost = try await realPollUntil {
          await clock.advance(by: .seconds(61))
          return received.machineLost()
        }
        #expect(lost, "a caller arriving after the machine's expiry must still fail after one grace")
        #expect(try await space.execRecord(exec)?.terminal == .machineLost)
        reader.cancel()
      }
      _ = try await group.next()
      group.cancelAll()
    }
  }

  @Test func agentRestartNeverRespawnsAFinishedExecAndDrainFailsBounded() async throws {
    let space = try makeMachineSpace()
    let clock = TestClock()
    let server = TestServer(space: space, clock: clock)
    let (machine, key) = try await addMachine(server)
    let firstState = try ScratchFolder("m4-agent")
    defer { firstState.remove() }
    let secondState = try ScratchFolder("m4-agent")
    defer { secondState.remove() }
    let firstAgent = makeAgent(state: firstState)
    let secondAgent = makeAgent(state: secondState)
    let firstDialer = AgentDialer()
    let secondDialer = AgentDialer()

    try await withThrowingTaskGroup(of: Void.self) { group in
      group.addTask { await server.run() }
      group.addTask { await firstAgent.run(dial: firstDialer.dial) }
      group.addTask { await secondAgent.run(dial: secondDialer.dial) }
      group.addTask {
        let firstMachineSocket = try await connectMachine(server, key: key)
        firstDialer.offer(firstMachineSocket)
        let exec = try await mintExec(server, machine: machine)

        let firstCaller = try await connectCaller(server, exec: exec)
        let firstLog = FrameLog()
        let firstReader = Task {
          for await message in firstCaller.inbound {
            guard case let .binary(bytes) = message, let frame = try? FrameCodec.decode(bytes) else { continue }
            firstLog.append(frame)
          }
          firstLog.finish()
        }
        let start = makeExecStart(exec, command: ["sh", "-c", "echo spawned"])
        try await firstCaller.send(.binary(FrameCodec.encode(Frame(streamID: 1, opcode: .execStart, payload: start))))
        let finished = try await realPollUntil {
          try await space.execRecord(exec)?.terminal == .exited(code: 0)
        }
        #expect(finished)
        firstCaller.close()
        firstReader.cancel()

        // The agent restart: a fresh process with none of the channel's
        // per-exec dedup state dials in for the same machine.
        firstMachineSocket.close()
        secondDialer.offer(try await connectMachine(server, key: key))

        let secondCaller = try await connectCaller(server, exec: exec)
        let secondLog = FrameLog()
        let secondReader = Task {
          for await message in secondCaller.inbound {
            guard case let .binary(bytes) = message, let frame = try? FrameCodec.decode(bytes) else { continue }
            secondLog.append(frame)
          }
          secondLog.finish()
        }
        try await secondCaller.send(.binary(FrameCodec.encode(Frame(streamID: 1, opcode: .execStart, payload: start))))

        let failed = try await realPollUntil {
          await clock.advance(by: .seconds(61))
          return secondLog.stalledDrain()
        }
        #expect(failed, "a terminal exec whose stream is gone must fail the drain within one grace")
        #expect(secondLog.outputText().isEmpty, "the finished command must never respawn")
        let closed = try await realPollUntil { secondLog.finished() }
        #expect(closed)
        #expect(try await space.execRecord(exec)?.terminal == .exited(code: 0))
        secondReader.cancel()
      }
      _ = try await group.next()
      group.cancelAll()
    }
  }

  @Test func machineGonePastGraceFailsTheCallerWithMachineLostAndPartialOutput() async throws {
    let space = try makeMachineSpace()
    let clock = TestClock()
    let server = TestServer(space: space, clock: clock)
    let (machine, key) = try await addMachine(server)
    let state = try ScratchFolder("m4-agent")
    defer { state.remove() }
    let agent = makeAgent(state: state)
    let dialer = AgentDialer()

    try await withThrowingTaskGroup(of: Void.self) { group in
      group.addTask { await server.run() }
      group.addTask { await agent.run(dial: dialer.dial) }
      group.addTask {
        let machineSocket = try await connectMachine(server, key: key)
        dialer.offer(machineSocket)
        let exec = try await mintExec(server, machine: machine)
        let callerSocket = try await connectCaller(server, exec: exec)

        let received = FrameLog()
        let reader = Task {
          for await message in callerSocket.inbound {
            guard case let .binary(bytes) = message, let frame = try? FrameCodec.decode(bytes) else { continue }
            received.append(frame)
          }
          received.finish()
        }

        let start = makeExecStart(exec, command: ["sh", "-c", "echo partial; exec sleep 1000"])
        try await callerSocket.send(.binary(FrameCodec.encode(Frame(streamID: 1, opcode: .execStart, payload: start))))

        let sawOutput = try await realPollUntil {
          received.outputText().contains("partial")
        }
        #expect(sawOutput)

        machineSocket.close()
        let lost = try await realPollUntil {
          await clock.advance(by: .seconds(61))
          return received.machineLost()
        }
        #expect(lost, "machine gone past grace must fail the caller with machine-lost")
        #expect(received.outputText().contains("partial"), "everything already delivered stays delivered")

        let closed = try await realPollUntil { received.finished() }
        #expect(closed, "the caller leg is closed after the failure")

        #expect(try await space.execRecord(exec)?.terminal == .machineLost)
        reader.cancel()
      }
      _ = try await group.next()
      group.cancelAll()
    }
  }
}

func processAlive(_ pid: Int32) -> Bool {
  kill(pid, 0) == 0
}

final class FrameLog: Sendable {
  private struct State {
    var frames: [Frame] = []
    var finished = false
  }

  private let state = Mutex(State())

  func append(_ frame: Frame) {
    state.withLock { $0.frames.append(frame) }
  }

  func finish() {
    state.withLock { $0.finished = true }
  }

  func finished() -> Bool {
    state.withLock { $0.finished }
  }

  func outputText() -> String {
    let chunks = state.withLock { $0.frames }
      .filter { $0.opcode == .output }
      .compactMap { try? $0.payload(OutputChunk.self) }
    var bytes: [UInt8] = []
    var consumed = 0
    for chunk in chunks.sorted(by: { $0.cursor < $1.cursor }) where chunk.cursor <= consumed {
      let fresh = chunk.data.bytes.dropFirst(consumed - chunk.cursor)
      bytes += fresh
      consumed = max(consumed, chunk.cursor + chunk.data.count)
    }
    return String(decoding: bytes, as: UTF8.self)
  }

  func machineLost() -> Bool {
    controlErrorCodes().contains(.machineLost)
  }

  func stalledDrain() -> Bool {
    controlErrorCodes().contains(.execNotFound)
  }

  private func controlErrorCodes() -> [MachineErrorCode] {
    state.withLock { $0.frames }.compactMap { frame in
      guard frame.opcode == .control, case let .error(error)? = try? frame.payload(ControlMessage.self) else { return nil }
      return error.code
    }
  }
}
