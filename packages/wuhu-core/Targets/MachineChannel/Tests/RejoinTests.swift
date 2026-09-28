import MachineChannel
import MachineContract
import Testing

@Suite(.timeLimit(.minutes(2)))
struct RejoinTests {
  @Test func freshEndpointResumesFromLastAckAfterCallerCrash() async throws {
    var rng = SplitMix64(seed: 0x5D5A_0001)
    let payload = randomBytes(4096, using: &rng)
    let chunks = randomChunks(of: payload, maxChunk: 512, using: &rng)
    let id = execID(9)
    let ackCursor = 1024

    let machine = ChannelEndpoint()
    let startCount = Box(0)
    try await withThrowingTaskGroup(of: Void.self) { group in
      group.addTask {
        await withTaskGroup(of: Void.self) { serving in
          for await exec in machine.incomingExecs {
            startCount.update { $0 += 1 }
            serving.addTask {
              for chunk in chunks {
                try? await exec.send(.stdout, chunk)
              }
              await exec.exit(.exited(code: 42))
            }
          }
        }
      }

      let firstLeg = InMemoryTransport.pair()
      let firstCaller = ChannelEndpoint()
      let exec = await firstCaller.startExec(makeStart(id), autoAcknowledge: false)
      group.addTask { await firstCaller.run(firstLeg.0) }
      group.addTask { await machine.run(firstLeg.1) }

      var iterator = exec.events.makeAsyncIterator()
      var consumed = 0
      while consumed < 2 * ackCursor {
        guard let event = try await iterator.next() else { break }
        if case let .output(_, _, data) = event {
          consumed += data.count
        }
      }
      #expect(consumed >= 2 * ackCursor)
      // Only the durable prefix is acknowledged; everything consumed past it
      // died with this caller and must be redelivered to the rejoin.
      await exec.acknowledge(through: ackCursor)
      firstLeg.0.sever()

      let secondCaller = ChannelEndpoint()
      let rejoined = await secondCaller.startExec(makeStart(id), resumingFrom: ackCursor)
      let secondLeg = InMemoryTransport.pair()
      group.addTask { await secondCaller.run(secondLeg.0) }
      group.addTask { await machine.run(secondLeg.1) }

      var tail: [UInt8] = []
      var cursor = ackCursor
      var exit: MachineContract.ExitStatus?
      for try await event in rejoined.events {
        switch event {
        case let .output(_, at, data):
          #expect(at == cursor)
          cursor += data.count
          tail += data.bytes
        case let .exit(status):
          exit = status
        default:
          break
        }
        if exit != nil { break }
      }
      #expect(tail == Array(payload[ackCursor...]))
      #expect(exit == .exited(code: 42))
      #expect(startCount.value == 1, "the exec-start retransmit must never respawn")
      group.cancelAll()
    }
  }

  @Test func rejoinAtFullConsumptionReceivesOnlyTheExit() async throws {
    var rng = SplitMix64(seed: 0x5D5A_0002)
    let payload = randomBytes(1500, using: &rng)
    let id = execID(10)

    let machine = ChannelEndpoint()
    try await withThrowingTaskGroup(of: Void.self) { group in
      group.addTask {
        await withTaskGroup(of: Void.self) { serving in
          for await exec in machine.incomingExecs {
            serving.addTask {
              try? await exec.send(.stdout, payload)
              await exec.exit(.exited(code: 0))
            }
          }
        }
      }

      let firstLeg = InMemoryTransport.pair()
      let firstCaller = ChannelEndpoint()
      let exec = await firstCaller.startExec(makeStart(id), autoAcknowledge: false)
      group.addTask { await firstCaller.run(firstLeg.0) }
      group.addTask { await machine.run(firstLeg.1) }

      var iterator = exec.events.makeAsyncIterator()
      var consumed = 0
      while consumed < payload.count {
        guard let event = try await iterator.next() else { break }
        if case let .output(_, _, data) = event {
          consumed += data.count
        }
      }
      await exec.acknowledge(through: payload.count)
      firstLeg.0.sever()

      let secondCaller = ChannelEndpoint()
      let rejoined = await secondCaller.startExec(makeStart(id), resumingFrom: payload.count)
      let secondLeg = InMemoryTransport.pair()
      group.addTask { await secondCaller.run(secondLeg.0) }
      group.addTask { await machine.run(secondLeg.1) }

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
      #expect(tail.isEmpty)
      #expect(exit == .exited(code: 0))
      group.cancelAll()
    }
  }
}
