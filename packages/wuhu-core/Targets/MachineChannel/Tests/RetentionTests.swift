import Clocks
import Dependencies
@testable import MachineChannel
import MachineContract
import Testing

@Suite(.timeLimit(.minutes(1)))
struct RetentionTests {
  @Test func terminalAckWhileUnboundIsResentOnRebindAndRetiresPromptly() async throws {
    let machine = ChannelEndpoint()
    let caller = ChannelEndpoint()
    let (a, b) = InMemoryTransport.pair()
    let callerUnbound = Checkpoint()
    let machineUnbound = Checkpoint()
    try await withThrowingTaskGroup(of: Void.self) { group in
      group.addTask { await machine.run(a); machineUnbound.signal() }
      group.addTask { await caller.run(b); callerUnbound.signal() }
      group.addTask {
        for await exec in machine.incomingExecs {
          try await exec.send(.stdout, [1, 2, 3])
          await exec.exit(.exited(code: 0))
        }
      }
      let outgoing = await caller.startExec(makeStart(execID(902)), autoAcknowledge: false)
      let result = try await collect(outgoing)
      #expect(result.stdout == [1, 2, 3])
      b.close()
      await callerUnbound.wait()
      await machineUnbound.wait()
      await outgoing.acknowledgeExit()
      #expect(await machine.retainedExecCount == 1)
      #expect(await caller.retainedExecCount == 1)
      let (c, d) = InMemoryTransport.pair()
      let tap = TapTransport(d)
      group.addTask { await machine.run(c) }
      group.addTask { await caller.run(tap) }
      for _ in 0 ..< 1000 {
        if await machine.retainedExecCount == 0, await caller.retainedExecCount == 0 { break }
        await Task.yield()
      }
      #expect(await machine.retainedExecCount == 0)
      #expect(await caller.retainedExecCount == 0)
      #expect(tap.sent.value.contains { $0.opcode == .ack && (try? $0.payload(Ack.self).terminal) == true })
      #expect(!tap.sent.value.contains { $0.opcode == .execStart })
      group.cancelAll()
    }
  }

  @Test func acknowledgedFinishedExecsLeaveNoHistoryForThreeHellos() async throws {
    let endpoint = ChannelEndpoint()
    let (raw, machine) = InMemoryTransport.pair()
    try await withThrowingTaskGroup(of: Void.self) { group in
      group.addTask { await endpoint.run(machine) }
      group.addTask { await endpoint.runRetention() }
      group.addTask { await serveRequestsOK(endpoint) }
      group.addTask {
        for await exec in endpoint.incomingExecs {
          try await exec.send(.stdout, [UInt8](repeating: 65, count: 16384))
          await exec.exit(.exited(code: 0))
        }
      }
      var iterator = raw.inbound.makeAsyncIterator()
      for n in 1 ... 64 {
        try await raw.send(FrameCodec.encode(Frame(streamID: n, opcode: .execStart, payload: makeStart(execID(n)))))
        while let bytes = await iterator.next() {
          if try FrameCodec.decode(bytes).opcode == .execExit { break }
        }
        try await raw.send(FrameCodec.encode(Frame(streamID: n, opcode: .ack, payload: Ack(id: execID(n), cursor: 16384, terminal: true))))
      }
      for _ in 0 ..< 3 {
        try await raw.send(FrameCodec.encode(Frame(streamID: 0, opcode: .control, payload: ControlMessage.hello(protocolVersion: 1))))
        let replay = try await barrier(raw, iterator: &iterator)
        #expect(replay.allSatisfy { $0.opcode != .output && $0.opcode != .execExit })
        #expect(await endpoint.retainedExecCount == 0)
      }
      raw.close()
      let (rejoined, rebound) = InMemoryTransport.pair()
      group.addTask { await endpoint.run(rebound) }
      var resumed = rejoined.inbound.makeAsyncIterator()
      let replay = try await barrier(rejoined, iterator: &resumed)
      #expect(replay.allSatisfy { $0.opcode != .output && $0.opcode != .execExit })
      group.cancelAll()
    }
  }

  @Test func scopedHelloReplaysOnlyItsExecAndByteAckDoesNotRetireExit() async throws {
    let endpoint = ChannelEndpoint()
    let (raw, machine) = InMemoryTransport.pair()
    try await withThrowingTaskGroup(of: Void.self) { group in
      group.addTask { await endpoint.run(machine) }
      group.addTask { await serveRequestsOK(endpoint) }
      group.addTask {
        for await exec in endpoint.incomingExecs {
          try await exec.send(.stdout, [1, 2, 3])
          await exec.exit(.exited(code: 0))
        }
      }
      var iterator = raw.inbound.makeAsyncIterator()
      for n in 1 ... 2 {
        try await raw.send(FrameCodec.encode(Frame(streamID: n, opcode: .execStart, payload: makeStart(execID(n)))))
        while let bytes = await iterator.next() {
          if try FrameCodec.decode(bytes).opcode == .execExit { break }
        }
      }
      try await raw.send(FrameCodec.encode(Frame(streamID: 0, opcode: .control, payload: ControlMessage.hello(protocolVersion: 1, execs: [execID(2)]))))
      let scoped = try await barrier(raw, iterator: &iterator)
      #expect(scoped.filter { $0.opcode == .output }.map(\.streamID) == [2])
      #expect(scoped.filter { $0.opcode == .execExit }.map(\.streamID) == [2])
      try await raw.send(FrameCodec.encode(Frame(streamID: 2, opcode: .ack, payload: Ack(id: execID(2), cursor: 3))))
      try await raw.send(FrameCodec.encode(Frame(streamID: 0, opcode: .control, payload: ControlMessage.hello(protocolVersion: 1, execs: [execID(2)]))))
      let acked = try await barrier(raw, iterator: &iterator)
      #expect(acked.filter { $0.opcode == .output }.isEmpty)
      #expect(acked.filter { $0.opcode == .execExit }.map(\.streamID) == [2])
      #expect(await endpoint.retainedExecCount == 2)
      group.cancelAll()
    }
  }

  @Test func unacknowledgedFinishedExecExpiresAfterTenMinutesEvenDisconnected() async throws {
    let clock = TestClock()
    let endpoint = withDependencies { $0.continuousClock = clock } operation: { ChannelEndpoint() }
    let caller = ChannelEndpoint()
    let (a, b) = InMemoryTransport.pair()
    let start = makeStart(execID(1))
    let outgoing = await caller.startExec(start, autoAcknowledge: false)
    try await withThrowingTaskGroup(of: Void.self) { group in
      group.addTask { await endpoint.runRetention() }
      group.addTask { await endpoint.run(a) }
      group.addTask { await caller.run(b) }
      group.addTask {
        for await exec in endpoint.incomingExecs {
          try await exec.send(.stdout, [1, 2, 3])
          await exec.exit(.exited(code: 0))
        }
      }
      let collected = try await collect(outgoing)
      #expect(collected.stdout == [1, 2, 3])
      a.close()
      await clock.advance(by: .seconds(599))
      #expect(await endpoint.retainedExecCount == 1)
      await clock.advance(by: .seconds(1))
      for _ in 0 ..< 1000 {
        if await endpoint.retainedExecCount == 0 { break }
        await Task.yield()
      }
      #expect(await endpoint.retainedExecCount == 0)
      group.cancelAll()
    }
  }

  private func barrier(_ raw: InMemoryTransport, iterator: inout AsyncStream<[UInt8]>.Iterator) async throws -> [Frame] {
    try await raw.send(FrameCodec.encode(Frame(streamID: 0, opcode: .vfsRequest, payload: VFSRequest(id: 123, op: .stat(path: "/")))))
    var frames: [Frame] = []
    while let bytes = await iterator.next() {
      let frame = try FrameCodec.decode(bytes)
      if frame.opcode == .vfsResponse { return frames }
      frames.append(frame)
    }
    return frames
  }
}

private struct HeldTerminalAck: FrameTransport {
  let base: any FrameTransport
  let reached: Checkpoint
  let release: Checkpoint
  var inbound: AsyncStream<[UInt8]> { base.inbound }
  func close() { base.close() }
  func send(_ bytes: [UInt8]) async throws {
    let frame = try FrameCodec.decode(bytes)
    if frame.opcode == .ack, try frame.payload(Ack.self).terminal == true {
      reached.signal()
      await release.wait()
    }
    try await base.send(bytes)
  }
}

private struct HeldReplay: FrameTransport {
  let base: TapTransport
  let reached: Checkpoint
  let release: Checkpoint
  var inbound: AsyncStream<[UInt8]> { base.inbound }
  func close() { base.close() }
  func send(_ bytes: [UInt8]) async throws {
    if try FrameCodec.decode(bytes).opcode == .output {
      reached.signal()
      await release.wait()
    }
    try await base.send(bytes)
  }
}

extension RetentionTests {
  @Test func terminalAckRacingRebindPreservesUnstoredOutputThenRetiresWithoutRespawn() async throws {
    let machine = ChannelEndpoint()
    let first = ChannelEndpoint()
    let start = makeStart(execID(901))
    let payload = Array(String(repeating: "recover every byte\n", count: 100).utf8)
    let count = Box(0)
    let (a, b) = InMemoryTransport.pair()
    try await withThrowingTaskGroup(of: Void.self) { group in
      group.addTask { await machine.runRetention() }
      group.addTask { await machine.run(a) }
      group.addTask { await first.run(b) }
      group.addTask {
        for await exec in machine.incomingExecs {
          count.update { $0 += 1 }
          try await exec.send(.stdout, payload)
          await exec.exit(.exited(code: 0))
        }
      }
      let original = await first.startExec(start, autoAcknowledge: false)
      #expect(try await collect(original).stdout == payload)
      #expect(await machine.retainedExecCount == 1)
      b.close()

      let recovered = ChannelEndpoint()
      let retry = await recovered.startExec(start, autoAcknowledge: false)
      let (c, d) = InMemoryTransport.pair()
      let reached = Checkpoint()
      let release = Checkpoint()
      group.addTask { await machine.run(c) }
      group.addTask { await recovered.run(HeldTerminalAck(base: d, reached: reached, release: release)) }
      let result = try await collect(retry)
      #expect(result.stdout == payload)
      #expect(result.exit == .exited(code: 0))
      #expect(count.value == 1)
      #expect(await machine.retainedExecCount == 1)

      // Storage is now committed. Cut the binding while its terminal ACK is in flight.
      let acked = Checkpoint()
      group.addTask { await retry.acknowledgeExit(); acked.signal() }
      await reached.wait()
      let (e, f) = InMemoryTransport.pair()
      let tap = TapTransport(f)
      let replayTap = TapTransport(e)
      let replayReached = Checkpoint()
      let replayRelease = Checkpoint()
      let newAckReached = Checkpoint()
      let newAckRelease = Checkpoint()
      group.addTask { await machine.run(HeldReplay(base: replayTap, reached: replayReached, release: replayRelease)) }
      group.addTask { await recovered.run(HeldTerminalAck(base: tap, reached: newAckReached, release: newAckRelease)) }
      await replayReached.wait()
      await newAckReached.wait()
      while tap.sent.value.isEmpty { await Task.yield() }
      #expect(await machine.retainedExecCount == 1)
      #expect(await recovered.retainedExecCount == 1)
      d.close()
      release.signal()
      newAckRelease.signal()
      await acked.wait()
      replayRelease.signal()
      while !replayTap.sent.value.contains(where: { $0.opcode == .execExit }) { await Task.yield() }
      for _ in 0 ..< 1000 {
        if await machine.retainedExecCount == 0 { break }
        await Task.yield()
      }
      #expect(await machine.retainedExecCount == 0)
      #expect(await recovered.retainedExecCount == 0)
      #expect(tap.sent.value.allSatisfy { $0.opcode != .execStart })
      #expect(count.value == 1)
      group.cancelAll()
    }
  }
}
