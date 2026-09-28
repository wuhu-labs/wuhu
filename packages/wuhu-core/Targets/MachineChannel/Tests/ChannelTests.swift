import MachineChannel
import MachineContract
import Testing

@Suite(.timeLimit(.minutes(2)))
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
      group.addTask { await serveRequestsOK(machine) }

      try await raw.send(FrameCodec.encode(Frame(streamID: 5, opcode: .execStart, payload: makeStart(execID(9)))))
      try await raw.send(FrameCodec.encode(Frame(streamID: 5, opcode: .stdin, payload: ControlMessage.ping)))
      try await raw.send(FrameCodec.encode(Frame(streamID: 0, opcode: .vfsRequest, payload: VFSRequest(id: 1, op: .stat(path: "/")))))

      var sawVFSResponse = false
      var sawExit = false
      for await bytes in raw.inbound {
        let frame = try FrameCodec.decode(bytes)
        if frame.opcode == .vfsResponse { sawVFSResponse = true }
        if frame.opcode == .execExit { sawExit = true }
        if sawVFSResponse, sawExit { break }
      }
      #expect(sawVFSResponse)
      #expect(sawExit)
      #expect(stdinError.value)
      group.cancelAll()
    }
  }
}
