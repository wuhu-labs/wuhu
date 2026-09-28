import MachineChannel
import MachineContract
import Testing

@Suite(.timeLimit(.minutes(2)))
struct BlipTests {
  @Test(arguments: 0 ..< 24)
  func streamsReassembleByteExactAcrossBlips(iteration: Int) async throws {
    var rng = SplitMix64(seed: 0xB11B_0000 ^ (UInt64(iteration) &* 0x9E37_79B9_7F4A_7C15))
    let window = [64, 256, 1024, 4096].randomElement(using: &rng)!
    let stdout = randomBytes(Int.random(in: 1000 ... 8000, using: &rng), using: &rng)
    let stderr = randomBytes(Int.random(in: 0 ... 4000, using: &rng), using: &rng)
    let stdinPayload = randomBytes(Int.random(in: 500 ... 6000, using: &rng), using: &rng)
    let budgets = (0 ..< Int.random(in: 2 ... 5, using: &rng)).map { _ in Int.random(in: 5 ... 150, using: &rng) }
    let stdinChunks = randomChunks(of: stdinPayload, maxChunk: 700, using: &rng)

    var outputPlan: [(ExecOutputStream, [UInt8])] = []
    var stdoutChunks = randomChunks(of: stdout, maxChunk: 900, using: &rng)[...]
    var stderrChunks = randomChunks(of: stderr, maxChunk: 900, using: &rng)[...]
    while !stdoutChunks.isEmpty || !stderrChunks.isEmpty {
      if !stdoutChunks.isEmpty, stderrChunks.isEmpty || Bool.random(using: &rng) {
        outputPlan.append((.stdout, stdoutChunks.removeFirst()))
      } else {
        outputPlan.append((.stderr, stderrChunks.removeFirst()))
      }
    }
    let plan = outputPlan

    let caller = ChannelEndpoint()
    let machine = ChannelEndpoint()
    let stdinLog = Box<[UInt8]>([])
    try await withThrowingTaskGroup(of: Void.self) { group in
      group.addTask { await drive(caller, machine, budgets: budgets) }
      group.addTask {
        await withTaskGroup(of: Void.self) { serving in
          for await exec in machine.incomingExecs {
            serving.addTask {
              await withTaskGroup(of: Void.self) { inner in
                inner.addTask {
                  var collected: [UInt8] = []
                  do {
                    for try await chunk in exec.stdin {
                      collected += chunk
                    }
                  } catch {}
                  let bytes = collected
                  stdinLog.update { $0 = bytes }
                }
                inner.addTask {
                  do {
                    for (stream, bytes) in plan {
                      try await exec.send(stream, bytes)
                    }
                  } catch {}
                }
                await inner.waitForAll()
              }
              await exec.exit(.exited(code: 42))
            }
          }
        }
      }
      let exec = await caller.startExec(makeStart(execID(1), window: window))
      group.addTask {
        for chunk in stdinChunks {
          try? await exec.sendStdin(chunk)
        }
        await exec.closeStdin()
      }
      let collected = try await collect(exec)
      #expect(collected.stdout == stdout)
      #expect(collected.stderr == stderr)
      #expect(collected.exit == .exited(code: 42))
      #expect(stdinLog.value == stdinPayload)
      group.cancelAll()
    }
  }

  // Window-pressure caller-leg blip over independent relay legs: the machine
  // sender is blocked on a full window, its last ack and the in-flight tail
  // died with the sever. The rebind announce-ack wakes the sender; hello-first
  // means the fresh chunk it emits follows the hello-triggered replay, so the
  // first post-rebind frame is at or below the consumer's watermark and the
  // heal is drop-free.
  @Test func callerLegBlipUnderWindowPressureReplaysBeforeFreshChunks() async throws {
    let window = 1024
    let piece = 256
    var rng = SplitMix64(seed: 0xF00D_CA11)
    let payload = randomBytes(4096, using: &rng)

    let caller = ChannelEndpoint()
    let machine = ChannelEndpoint()
    let machineLeg = InMemoryTransport.pair()
    let machineSentEnd = Box(0)
    let callerRelaySide = Box<InMemoryTransport?>(nil)
    let lossy = Box(true)
    let firstOutputCursorAfterRebind = Box<Int?>(nil)

    try await withThrowingTaskGroup(of: Void.self) { group in
      group.addTask { await machine.run(machineLeg.0) }
      group.addTask {
        for await bytes in machineLeg.1.inbound {
          guard let frame = try? FrameCodec.decode(bytes) else { continue }
          if frame.opcode == .output, let chunk = try? frame.payload(OutputChunk.self) {
            machineSentEnd.update { $0 = max($0, chunk.cursor + chunk.data.count) }
            if lossy.value {
              if chunk.cursor + chunk.data.count > 2 * piece { continue }
            } else {
              firstOutputCursorAfterRebind.update { if $0 == nil { $0 = chunk.cursor } }
            }
          }
          try? await callerRelaySide.value?.send(bytes)
        }
      }
      group.addTask {
        await withTaskGroup(of: Void.self) { serving in
          for await exec in machine.incomingExecs {
            serving.addTask {
              for start in stride(from: 0, to: payload.count, by: piece) {
                try? await exec.send(.stdout, Array(payload[start ..< min(start + piece, payload.count)]))
              }
              await exec.exit(.exited(code: 7))
            }
          }
        }
      }

      let leg1 = InMemoryTransport.pair()
      callerRelaySide.update { $0 = leg1.1 }
      group.addTask { await caller.run(leg1.0) }
      group.addTask {
        for await bytes in leg1.1.inbound {
          guard let frame = try? FrameCodec.decode(bytes) else { continue }
          if frame.opcode == .ack, let ack = try? frame.payload(Ack.self), ack.cursor > piece { continue }
          try? await machineLeg.1.send(bytes)
        }
      }

      let exec = await caller.startExec(makeStart(execID(1), window: window))
      await exec.closeStdin()
      var events = exec.events.makeAsyncIterator()
      var stdout: [UInt8] = []
      var exit: MachineContract.ExitStatus?
      while stdout.count < 2 * piece, let event = try await events.next() {
        if case let .output(_, _, data) = event { stdout += data.bytes }
      }
      #expect(stdout.count == 2 * piece)

      while machineSentEnd.value < piece + window {
        await Task.yield()
      }
      lossy.update { $0 = false }
      leg1.0.sever()

      let leg2 = InMemoryTransport.pair()
      callerRelaySide.update { $0 = leg2.1 }
      group.addTask { await caller.run(leg2.0) }
      group.addTask {
        // After the rebind announce-ack lands, hold the next frame until the
        // woken sender has provably emitted its fresh chunk — the scheduling
        // gap real sockets always leave between the ack and the hello.
        for await bytes in leg2.1.inbound {
          let frame = try? FrameCodec.decode(bytes)
          try? await machineLeg.1.send(bytes)
          if frame?.opcode == .ack {
            while machineSentEnd.value < piece + window + piece {
              await Task.yield()
            }
          }
        }
      }

      while let event = try await events.next() {
        switch event {
        case let .output(_, _, data): stdout += data.bytes
        case let .exit(status): exit = status
        default: break
        }
      }
      #expect(stdout == payload)
      #expect(exit == .exited(code: 7))
      let firstCursor = try #require(firstOutputCursorAfterRebind.value)
      #expect(firstCursor <= 2 * piece)
      group.cancelAll()
    }
  }

  // The stdin mirror: the caller is the window-blocked sender, the machine leg
  // blips, and the machine's rebind announce-ack must not let fresh stdin
  // overtake the hello-triggered stdin replay.
  @Test func machineLegBlipUnderWindowPressureReplaysBeforeFreshStdin() async throws {
    let window = 1024
    let piece = 256
    var rng = SplitMix64(seed: 0x51D1_B11B)
    let payload = randomBytes(4096, using: &rng)

    let caller = ChannelEndpoint()
    let machine = ChannelEndpoint()
    let callerLeg = InMemoryTransport.pair()
    let callerSentEnd = Box(0)
    let machineRelaySide = Box<InMemoryTransport?>(nil)
    let lossy = Box(true)
    let firstStdinCursorAfterRebind = Box<Int?>(nil)
    let collectedStdin = Box<[UInt8]>([])
    let stdinFailure = Box<String?>(nil)

    try await withThrowingTaskGroup(of: Void.self) { group in
      group.addTask { await caller.run(callerLeg.0) }
      group.addTask {
        for await bytes in callerLeg.1.inbound {
          guard let frame = try? FrameCodec.decode(bytes) else { continue }
          if frame.opcode == .stdin, let chunk = try? frame.payload(StdinChunk.self) {
            callerSentEnd.update { $0 = max($0, chunk.cursor + chunk.data.count) }
            if lossy.value {
              if chunk.cursor + chunk.data.count > 2 * piece { continue }
            } else {
              firstStdinCursorAfterRebind.update { if $0 == nil { $0 = chunk.cursor } }
            }
          }
          try? await machineRelaySide.value?.send(bytes)
        }
      }
      group.addTask {
        await withTaskGroup(of: Void.self) { serving in
          for await exec in machine.incomingExecs {
            serving.addTask {
              do {
                var collected: [UInt8] = []
                for try await chunk in exec.stdin {
                  collected += chunk
                }
                let bytes = collected
                collectedStdin.update { $0 = bytes }
              } catch {
                stdinFailure.update { $0 = "\(error)" }
              }
              await exec.exit(.exited(code: 3))
            }
          }
        }
      }

      let legM1 = InMemoryTransport.pair()
      machineRelaySide.update { $0 = legM1.1 }
      group.addTask { await machine.run(legM1.0) }
      group.addTask {
        for await bytes in legM1.1.inbound {
          guard let frame = try? FrameCodec.decode(bytes) else { continue }
          if frame.opcode == .ack, let ack = try? frame.payload(Ack.self), ack.cursor > piece { continue }
          try? await callerLeg.1.send(bytes)
        }
      }

      let exec = await caller.startExec(makeStart(execID(1), window: window))
      group.addTask {
        for start in stride(from: 0, to: payload.count, by: piece) {
          try? await exec.sendStdin(Array(payload[start ..< min(start + piece, payload.count)]))
        }
        await exec.closeStdin()
      }

      while callerSentEnd.value < piece + window {
        await Task.yield()
      }
      lossy.update { $0 = false }
      legM1.0.sever()

      let legM2 = InMemoryTransport.pair()
      machineRelaySide.update { $0 = legM2.1 }
      group.addTask { await machine.run(legM2.0) }
      group.addTask {
        // Mirror of the caller-blip pump: give the woken stdin sender the
        // scheduling gap between the rebind announce-ack and the next frame.
        for await bytes in legM2.1.inbound {
          let frame = try? FrameCodec.decode(bytes)
          try? await callerLeg.1.send(bytes)
          if frame?.opcode == .ack {
            while callerSentEnd.value < piece + window + piece {
              await Task.yield()
            }
          }
        }
      }

      let collected = try await collect(exec)
      #expect(collected.exit == .exited(code: 3))
      #expect(collectedStdin.value == payload)
      #expect(stdinFailure.value == nil)
      let firstCursor = try #require(firstStdinCursorAfterRebind.value)
      #expect(firstCursor <= 2 * piece)
      group.cancelAll()
    }
  }

  // A relay forwards into whichever leg is bound, so after a blip a fresh
  // chunk (or exit) can arrive ahead of the replay that covers the frames
  // dropped while the leg was down. The receiver must drop the racer and heal
  // from the replay, not abort on a gap.
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

  @Test func stdinRacingAheadOfItsReplayIsHealedByTheReplay() async throws {
    let machine = ChannelEndpoint()
    let (a, b) = InMemoryTransport.pair()
    let payload = Array("stdin replays across the race too".utf8)
    let head = Array(payload[..<10])
    let tail = Array(payload[10...])
    let stdinLog = Box<[ExecID: [UInt8]]>([:])
    try await withThrowingTaskGroup(of: Void.self) { group in
      group.addTask { await machine.run(a) }
      group.addTask { await serveEcho(machine, stdinLog: stdinLog) }
      try await b.send(FrameCodec.encode(Frame(streamID: 1, opcode: .execStart, payload: makeStart(execID(1)))))
      try await b.send(stdinFrame(execID(1), cursor: 10, bytes: tail))
      try await b.send(eofFrame(execID(1), cursor: payload.count))
      try await b.send(stdinFrame(execID(1), cursor: 0, bytes: head))
      try await b.send(stdinFrame(execID(1), cursor: 10, bytes: tail))
      try await b.send(eofFrame(execID(1), cursor: payload.count))
      var exited = false
      for await bytes in b.inbound {
        if let frame = try? FrameCodec.decode(bytes), frame.opcode == .execExit {
          exited = true
          break
        }
      }
      #expect(exited)
      #expect(stdinLog.value == [execID(1): payload])
      group.cancelAll()
    }
  }

  @Test func execStartIsDeliveredAtMostOnceAcrossBlips() async throws {
    let caller = ChannelEndpoint()
    let machine = ChannelEndpoint()
    let startCounts = Box<[ExecID: Int]>([:])
    try await withThrowingTaskGroup(of: Void.self) { group in
      group.addTask { await drive(caller, machine, budgets: [1, 2, 3, 5, 8]) }
      group.addTask { await serveEcho(machine, startCounts: startCounts) }
      let exec = await caller.startExec(makeStart(execID(1)))
      await exec.closeStdin()
      let collected = try await collect(exec)
      #expect(collected.exit == .exited(code: 0))
      #expect(startCounts.value == [execID(1): 1])
      group.cancelAll()
    }
  }
}
