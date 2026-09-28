import MachineChannel
import MachineContract
import Testing

@Suite(.timeLimit(.minutes(2)))
struct FlowControlTests {
  @Test func producerStallsAtExactlyWindowUntilConsumptionAcks() async throws {
    let caller = ChannelEndpoint()
    let machine = ChannelEndpoint()
    let (callerSide, machineSide) = InMemoryTransport.pair()
    let tap = TapTransport(machineSide)
    let sentAll = Box(false)
    var rng = SplitMix64(seed: 1)
    let payload = randomBytes(20, using: &rng)
    try await withThrowingTaskGroup(of: Void.self) { group in
      group.addTask { await caller.run(callerSide) }
      group.addTask { await machine.run(tap) }
      group.addTask {
        await withTaskGroup(of: Void.self) { inner in
          for await exec in machine.incomingExecs {
            inner.addTask {
              try? await exec.send(.stdout, payload)
              sentAll.update { $0 = true }
              await exec.exit(.exited(code: 0))
            }
          }
        }
      }
      let exec = await caller.startExec(makeStart(execID(1), window: 8))
      while tap.outputBytes() < 8 {
        await Task.yield()
      }
      #expect(tap.outputBytes() == 8)
      #expect(sentAll.value == false)
      let collected = try await collect(exec)
      #expect(collected.stdout == payload)
      #expect(collected.exit == .exited(code: 0))
      #expect(sentAll.value == true)
      #expect(tap.outputChunks().allSatisfy { $0.data.count <= 8 })
      group.cancelAll()
    }
  }

  @Test func windowCountsDecodedRawBytesNotBase64Characters() async throws {
    let caller = ChannelEndpoint()
    let machine = ChannelEndpoint()
    let (callerSide, machineSide) = InMemoryTransport.pair()
    let tap = TapTransport(machineSide)
    let sentAll = Checkpoint()
    try await withThrowingTaskGroup(of: Void.self) { group in
      group.addTask { await caller.run(callerSide) }
      group.addTask { await machine.run(tap) }
      group.addTask {
        await withTaskGroup(of: Void.self) { inner in
          for await exec in machine.incomingExecs {
            inner.addTask {
              // 5 raw bytes are 8 base64 chars; a chars-counting window of 6 would stall here.
              try? await exec.send(.stdout, [104, 101, 108, 108, 111])
              try? await exec.send(.stdout, [33])
              sentAll.signal()
              await exec.exit(.exited(code: 0))
            }
          }
        }
      }
      let exec = await caller.startExec(makeStart(execID(1), window: 6))
      await sentAll.wait()
      while tap.outputChunks().count < 2 {
        await Task.yield()
      }
      #expect(tap.outputChunks().map(\.cursor) == [0, 5])
      let collected = try await collect(exec)
      #expect(collected.stdout == [104, 101, 108, 108, 111, 33])
      group.cancelAll()
    }
  }

  @Test func replayBufferTrimsExactlyOnAckAndUnackedTailSurvivesSever() async throws {
    let caller = ChannelEndpoint()
    let machine = ChannelEndpoint()
    let consumedFirst = Checkpoint()
    let ackApplied = Checkpoint()
    let severed = Checkpoint()
    try await withThrowingTaskGroup(of: Void.self) { group in
      group.addTask { await serveRequestsOK(caller) }
      group.addTask {
        await withTaskGroup(of: Void.self) { inner in
          for await exec in machine.incomingExecs {
            inner.addTask {
              try? await exec.send(.stdout, [0, 1, 2, 3])
              try? await exec.send(.stdout, [4, 5, 6, 7, 8, 9])
              await consumedFirst.wait()
              // The vfs round trip is a barrier: the caller's ack(4) was queued
              // before its response, so once this returns the ack is applied.
              _ = try? await machine.vfs(.stat(path: "/"))
              ackApplied.signal()
              await severed.wait()
              await exec.exit(.exited(code: 0))
            }
          }
        }
      }

      let first = InMemoryTransport.pair()
      async let callerRunFirst: Void = caller.run(first.0)
      async let machineRunFirst: Void = machine.run(first.1)

      let exec = await caller.startExec(makeStart(execID(1), window: 1024))
      var events = exec.events.makeAsyncIterator()
      guard case let .output(_, 0, data)? = try await events.next(), data.bytes == [0, 1, 2, 3] else {
        Issue.record("unexpected first event")
        group.cancelAll()
        return
      }
      consumedFirst.signal()
      await ackApplied.wait()
      first.0.sever()
      _ = await (callerRunFirst, machineRunFirst)

      let second = InMemoryTransport.pair()
      let tap = TapTransport(second.1)
      group.addTask { await caller.run(second.0) }
      group.addTask { await machine.run(tap) }
      severed.signal()

      guard case let .output(_, 4, tail)? = try await events.next() else {
        Issue.record("missing replayed tail")
        group.cancelAll()
        return
      }
      #expect(tail.bytes == [4, 5, 6, 7, 8, 9])
      guard case .exit(status: .exited(code: 0))? = try await events.next() else {
        Issue.record("missing exit")
        group.cancelAll()
        return
      }
      // Rebind may replay the tail more than once (own bind replay plus the
      // peer's resume announcement); trim exactness means no replayed chunk
      // ever carries the acked bytes below cursor 4.
      let replayed = tap.outputChunks()
      #expect(!replayed.isEmpty)
      #expect(replayed.allSatisfy { $0.cursor == 4 && $0.data.count == 6 })
      group.cancelAll()
    }
  }
}
