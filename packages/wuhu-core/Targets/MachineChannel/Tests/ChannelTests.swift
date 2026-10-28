import Clocks
import DeterministicDependencies
import MachineChannel
import MachineContract
import Testing

@Suite(.deterministicDependencies(clock: TestClock()), .timeLimit(.minutes(2)))
struct ChannelTests {
  @Test func execRoundTripsStdinToOutputAndExit() async throws {
    let caller = ChannelEndpoint()
    let machine = ChannelEndpoint()
    let payload = Array("hello machine".utf8)
    try await withThrowingTaskGroup(of: Void.self) { group in
      group.addTask { await drive(caller, machine) }
      group.addTask { await serveEcho(machine) }
      let exec = await caller.startExec(makeStart(execID(1)))
      group.addTask {
        try? await exec.sendStdin(payload)
        await exec.closeStdin()
      }
      let collected = try await collect(exec)
      #expect(collected.stdout == payload)
      #expect(collected.stderr.isEmpty)
      #expect(collected.exit == .exited(code: 0))
      group.cancelAll()
    }
  }

  @Test func execStartedBeforeBindingIsDeliveredOnBind() async throws {
    let caller = ChannelEndpoint()
    let machine = ChannelEndpoint()
    let exec = await caller.startExec(makeStart(execID(1)))
    try await withThrowingTaskGroup(of: Void.self) { group in
      group.addTask { await serveEcho(machine) }
      group.addTask {
        try? await exec.sendStdin([1, 2, 3])
        await exec.closeStdin()
      }
      group.addTask { await drive(caller, machine) }
      let collected = try await collect(exec)
      #expect(collected.stdout == [1, 2, 3])
      #expect(collected.exit == .exited(code: 0))
      group.cancelAll()
    }
  }

  @Test func killIsDeliveredOnceAndExitFlowsBack() async throws {
    let caller = ChannelEndpoint()
    let machine = ChannelEndpoint()
    let killCount = Box(0)
    try await withThrowingTaskGroup(of: Void.self) { group in
      group.addTask { await drive(caller, machine) }
      group.addTask {
        await withTaskGroup(of: Void.self) { inner in
          for await exec in machine.incomingExecs {
            inner.addTask {
              for await _ in exec.kills {
                killCount.update { $0 += 1 }
              }
              await exec.exit(.signaled(signal: 15))
            }
          }
        }
      }
      let exec = await caller.startExec(makeStart(execID(1)))
      await exec.kill()
      await exec.kill()
      let collected = try await collect(exec)
      #expect(collected.exit == .signaled(signal: 15))
      #expect(killCount.value == 1)
      group.cancelAll()
    }
  }

  @Test func aTimedOutExitAnnouncesTheCutThenTheTimeoutThenTheExit() async throws {
    let caller = ChannelEndpoint()
    let machine = ChannelEndpoint()
    try await withThrowingTaskGroup(of: Void.self) { group in
      group.addTask { await drive(caller, machine) }
      group.addTask {
        for await exec in machine.incomingExecs {
          await exec.stopOutput()
          await exec.exit(.signaled(signal: 9), timedOut: .killed)
        }
      }
      let exec = await caller.startExec(makeStart(execID(1)))
      var events: [String] = []
      for try await event in exec.events {
        switch event {
        case .truncated: events.append("truncated")
        case let .timedOut(outcome): events.append("timedOut \(outcome)")
        case let .exit(status): events.append("exit \(status)")
        default: events.append("\(event)")
        }
      }
      #expect(events == ["truncated", "timedOut killed", "exit signaled(signal: 9)"])
      group.cancelAll()
    }
  }

  @Test func malformedStreamBodyFailsOnlyThatExec() async throws {
    let machine = ChannelEndpoint()
    let (raw, machineSide) = InMemoryTransport.pair()
    let stdinError = Box<Bool>(false)
    try await withThrowingTaskGroup(of: Void.self) { group in
      group.addTask { await machine.run(machineSide) }
      group.addTask {
        await withTaskGroup(of: Void.self) { inner in
          for await exec in machine.incomingExecs {
            inner.addTask {
              if exec.start.id == execID(10) {
                await exec.exit(.exited(code: 0))
                return
              }
              do {
                for try await _ in exec.stdin {}
              } catch {
                stdinError.update { $0 = true }
                await exec.exit(.exited(code: 1))
              }
            }
          }
        }
      }

      try await raw.send(FrameCodec.encode(Frame(streamID: 5, opcode: .execStart, payload: makeStart(execID(9)))))
      try await raw.send(FrameCodec.encode(Frame(streamID: 5, opcode: .stdin, payload: ControlMessage.ping)))
      try await raw.send(FrameCodec.encode(Frame(streamID: 6, opcode: .execStart, payload: makeStart(execID(10)))))

      var exits: [ExecID: MachineContract.ExitStatus] = [:]
      for await bytes in raw.inbound {
        let frame = try FrameCodec.decode(bytes)
        if frame.opcode == .execExit {
          let exit = try frame.payload(ExecExit.self)
          exits[exit.id] = exit.status
        }
        if exits.count == 2 { break }
      }
      #expect(exits[execID(9)] == .exited(code: 1))
      #expect(exits[execID(10)] == .exited(code: 0))
      #expect(stdinError.value)
      group.cancelAll()
    }
  }

  @Test func malformedFrameGetsControlErrorAndThePumpSurvives() async throws {
    let endpoint = ChannelEndpoint()
    let (raw, machine) = InMemoryTransport.pair()
    try await withThrowingTaskGroup(of: Void.self) { group in
      group.addTask { await endpoint.run(machine) }
      group.addTask {
        for await exec in endpoint.incomingExecs {
          await exec.exit(.exited(code: 0))
        }
      }
      try await raw.send(Array("definitely not a frame".utf8))
      try await raw.send(FrameCodec.encode(Frame(streamID: 1, opcode: .execStart, payload: makeStart(execID(1)))))
      var protocolError: MachineError?
      var exit: ExecExit?
      for await bytes in raw.inbound {
        let frame = try FrameCodec.decode(bytes)
        if frame.opcode == .control, case let .error(error) = try frame.payload(ControlMessage.self) {
          protocolError = error
        }
        if frame.opcode == .execExit { exit = try frame.payload(ExecExit.self) }
        if protocolError != nil, exit != nil { break }
      }
      #expect(protocolError?.code == .protocolViolation)
      #expect(exit?.status == .exited(code: 0))
      group.cancelAll()
    }
  }
}
