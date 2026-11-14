import DeterministicDependencies
import MachineChannel
import MachineContract
import Testing

/// The outgoing endpoint's wire behaviours: window backpressure, replay ahead of fresh data, and the pending
/// terminal-ack intent. The fake receiver plays the wire the way `ExecSocketLink` does and acknowledges stdin only
/// when its script consumes it, so the caller's window stays closed until the script reads.
@Suite(.deterministicDependencies, .timeLimit(.minutes(1)))
struct ExecCallerTests {
  @Test func rebindReplaysUnackedStdinBeforeFreshStdin() async throws {
    let endpoint = ChannelEndpoint()
    let start = ExecStart(id: execID(1), cwd: "/", command: ["cat"], window: 4)
    let exec = await endpoint.startExec(start)

    let first = InMemoryTransport.pair()
    let firstFrames = Box<[Frame]>([])
    let blocked = Gate()
    let firstUnbound = Gate()
    let firstTap = FrameTap(first.0) { frame in
      firstFrames.withLock { $0.append(frame) }
      if let chunk = frame.stdinChunk, chunk.cursor >= 4 { blocked.open() }
    }

    let second = InMemoryTransport.pair()
    let secondFrames = Box<[Frame]>([])
    let freshSent = Gate()
    let secondTap = FrameTap(second.0) { frame in
      secondFrames.withLock { $0.append(frame) }
      if let chunk = frame.stdinChunk, chunk.cursor >= 8 { freshSent.open() }
    }

    try await withThrowingTaskGroup(of: Void.self) { group in
      group.addTask { await endpoint.run(firstTap); firstUnbound.open() }
      group.addTask {
        await ScriptedExecReceiver { exec in
          var input = exec.stdin.makeAsyncIterator()
          if let chunk = try? await input.next() {
            await exec.acknowledgeStdin(through: chunk.cursor + chunk.bytes.count)
          }
        }.run(first.1)
      }
      group.addTask {
        try? await exec.sendStdin([1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12])
      }
      // One 4-byte chunk acked, four in flight, so the sender is suspended at the window when the leg dies.
      await blocked.wait()
      first.1.close()
      await firstUnbound.wait()

      group.addTask { await endpoint.run(secondTap) }
      group.addTask {
        await ScriptedExecReceiver { exec in
          do {
            for try await chunk in exec.stdin {
              await exec.acknowledgeStdin(through: chunk.cursor + chunk.bytes.count)
            }
          } catch {}
        }.run(second.1)
      }
      await freshSent.wait()
      let cursors = secondFrames.value.compactMap { $0.stdinChunk?.cursor }
      #expect(cursors == [4, 8])
      let startIndex = try #require(secondFrames.value.firstIndex { $0.opcode == .execStart })
      let firstStdinIndex = try #require(secondFrames.value.firstIndex { $0.stdinChunk != nil })
      #expect(startIndex < firstStdinIndex)
      group.cancelAll()
    }
  }

  @Test func stdinStopsAtTheWindowUntilAConsumptionAckFreesRoom() async throws {
    let endpoint = ChannelEndpoint()
    let start = ExecStart(id: execID(1), cwd: "/", command: ["cat"], window: 4)
    let (caller, peer) = InMemoryTransport.pair()
    let log = Box<[String]>([])
    let frames = Box<[Frame]>([])
    let marker = execID(2)
    let firstSent = Gate()
    let marked = Gate()
    let ackedAll = Gate()
    let sentAll = Gate()
    let consume = Gate()
    let tap = FrameTap(caller) { frame in
      frames.withLock { $0.append(frame) }
      if let chunk = frame.stdinChunk {
        log.withLock { $0.append("stdin \(chunk.cursor)+\(chunk.data.bytes.count)") }
        firstSent.open()
      }
      if frame.opcode == .execStart, (try? frame.payload(ExecStart.self))?.id == marker { marked.open() }
    }
    let receiver = FrameTap(peer) { frame in
      guard frame.opcode == .ack, let ack = try? frame.payload(Ack.self) else { return }
      log.withLock { $0.append("ack \(ack.cursor)") }
      if ack.cursor == 8 { ackedAll.open() }
    }

    try await withThrowingTaskGroup(of: Void.self) { group in
      group.addTask { await endpoint.run(tap) }
      group.addTask {
        await ScriptedExecReceiver { exec in
          await consume.wait()
          do {
            for try await chunk in exec.stdin {
              await exec.acknowledgeStdin(through: chunk.cursor + chunk.bytes.count)
            }
          } catch {}
        }.run(receiver)
      }
      let exec = await endpoint.startExec(start)
      group.addTask {
        try? await exec.sendStdin([1, 2, 3, 4, 5, 6, 7, 8])
        sentAll.open()
      }
      await firstSent.wait()
      // A second exec's start queues behind whatever the stdin sender has already produced: if the window did not
      // stop it, both chunks are ahead of the marker.
      _ = await endpoint.startExec(makeStart(marker))
      await marked.wait()
      let beforeMarker = frames.value.prefix {
        !($0.opcode == .execStart && (try? $0.payload(ExecStart.self))?.id == marker)
      }
      #expect(beforeMarker.compactMap { $0.stdinChunk?.cursor } == [0])
      consume.open()
      await ackedAll.wait()
      await sentAll.wait()
      #expect(log.value.filter { $0 != "ack 0" } == ["stdin 0+4", "ack 4", "stdin 4+4", "ack 8"])
      group.cancelAll()
    }
  }

  @Test func outputRacingAheadOfItsReplayIsHealedByTheReplay() async throws {
    let caller = ChannelEndpoint()
    let (a, b) = InMemoryTransport.pair()
    let payload = Array("the replay carries every dropped byte".utf8)
    let head = Array(payload[..<20])
    let tail = Array(payload[20...])
    try await withThrowingTaskGroup(of: Void.self) { group in
      group.addTask { await caller.run(a) }
      let exec = await caller.startExec(makeStart(execID(1)))
      await exec.closeStdin()
      try await b.send(outputFrame(execID(1), cursor: 20, bytes: tail))
      try await b.send(exitFrame(execID(1), cursor: payload.count))
      try await b.send(outputFrame(execID(1), cursor: 0, bytes: head))
      try await b.send(outputFrame(execID(1), cursor: 20, bytes: tail))
      try await b.send(exitFrame(execID(1), cursor: payload.count))
      let collected = try await collect(exec)
      #expect(collected.stdout == payload)
      #expect(collected.exit == .exited(code: 42))
      group.cancelAll()
    }
  }

  @Test func terminalAckWhileUnboundIsResentOnRebindAndRetiresPromptly() async throws {
    let caller = ChannelEndpoint()
    let start = makeStart(execID(902))
    let outgoing = await caller.startExec(start, autoAcknowledge: false)
    let first = InMemoryTransport.pair()
    let firstUnbound = Gate()
    try await withThrowingTaskGroup(of: Void.self) { group in
      group.addTask { await caller.run(first.0); firstUnbound.open() }
      try await first.1.send(outputFrame(start.id, cursor: 0, bytes: [1, 2, 3]))
      try await first.1.send(exitFrame(start.id, cursor: 3, status: .exited(code: 0)))
      let collected = try await collect(outgoing)
      #expect(collected.stdout == [1, 2, 3])
      #expect(collected.exit == .exited(code: 0))
      first.1.close()
      await firstUnbound.wait()
      // Unbound: the terminal-ack intent is recorded without a frame to carry it.
      await outgoing.acknowledgeExit()

      let second = InMemoryTransport.pair()
      let secondFrames = Box<[Frame]>([])
      let resent = Gate()
      let secondTap = FrameTap(second.0) { frame in
        secondFrames.withLock { $0.append(frame) }
        if frame.opcode == .ack, (try? frame.payload(Ack.self))?.terminal == true { resent.open() }
      }
      group.addTask { await caller.run(secondTap) }
      await resent.wait()
      #expect(secondFrames.value.map(\.opcode) == [.control, .ack])
      // Returning from this call means the resend was sent, so its send retired the exec.
      await outgoing.acknowledgeExit()

      let third = InMemoryTransport.pair()
      let thirdFrames = Box<[Frame]>([])
      let hello = Gate()
      let otherStart = Gate()
      let other = execID(2)
      let thirdTap = FrameTap(third.0) { frame in
        thirdFrames.withLock { $0.append(frame) }
        if frame.opcode == .control { hello.open() }
        if frame.opcode == .execStart, (try? frame.payload(ExecStart.self))?.id == other { otherStart.open() }
      }
      group.addTask { await caller.run(thirdTap) }
      await hello.wait()
      _ = await caller.startExec(makeStart(other))
      await otherStart.wait()
      let before = thirdFrames.value.prefix { frame in
        !(frame.opcode == .execStart && (try? frame.payload(ExecStart.self))?.id == other)
      }
      #expect(before.map(\.opcode) == [.control])
      group.cancelAll()
    }
  }
}

private func execID(_ n: Int) -> ExecID {
  let digits = String(n)
  return ExecID(rawValue: "ex_t" + String(repeating: "0", count: 7 - digits.count) + digits)
}

private func makeStart(_ id: ExecID, window: Int? = nil) -> ExecStart {
  ExecStart(id: id, cwd: "/", command: ["true"], window: window)
}

private func outputFrame(_ id: ExecID, cursor: Int, bytes: [UInt8]) -> [UInt8] {
  FrameCodec.encode(Frame(streamID: 1, opcode: .output, payload: OutputChunk(id: id, stream: .stdout, cursor: cursor, data: Base64Data(bytes))))
}

private func exitFrame(_ id: ExecID, cursor: Int, status: MachineContract.ExitStatus = .exited(code: 42)) -> [UInt8] {
  FrameCodec.encode(Frame(streamID: 1, opcode: .execExit, payload: ExecExit(id: id, cursor: cursor, status: status)))
}

private struct Collected {
  var stdout: [UInt8] = []
  var stderr: [UInt8] = []
  var exit: MachineContract.ExitStatus?
}

private func collect(_ exec: OutgoingExec) async throws -> Collected {
  var collected = Collected()
  var merged = 0
  for try await event in exec.events {
    switch event {
    case let .output(stream, cursor, data):
      #expect(cursor == merged)
      merged += data.bytes.count
      switch stream {
      case .stdout: collected.stdout += data.bytes
      case .stderr: collected.stderr += data.bytes
      }
    case let .exit(status):
      collected.exit = status
    default:
      break
    }
  }
  return collected
}

private struct FrameTap: FrameTransport {
  let base: InMemoryTransport
  let record: @Sendable (Frame) -> Void

  init(_ base: InMemoryTransport, record: @escaping @Sendable (Frame) -> Void) {
    self.base = base
    self.record = record
  }

  var inbound: AsyncStream<[UInt8]> { base.inbound }
  func close() { base.close() }
  func send(_ bytes: [UInt8]) async throws {
    if let frame = try? FrameCodec.decode(bytes) { record(frame) }
    try await base.send(bytes)
  }
}

private extension Frame {
  var stdinChunk: StdinChunk? {
    opcode == .stdin ? try? payload(StdinChunk.self) : nil
  }
}
