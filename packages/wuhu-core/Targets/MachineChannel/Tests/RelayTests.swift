import MachineChannel
import MachineContract
import Testing

@Suite(.timeLimit(.minutes(2)))
struct RelayTests {
  @Test func execRoundTripsThroughStatelessRelay() async throws {
    let caller = ChannelEndpoint()
    let machine = ChannelEndpoint()
    let relay = Relay()
    let payload = Array("through the relay".utf8)
    try await withThrowingTaskGroup(of: Void.self) { group in
      let legA = InMemoryTransport.pair()
      let legB = InMemoryTransport.pair()
      group.addTask { await caller.run(legA.0) }
      group.addTask { await relay.runA(legA.1) }
      group.addTask { await relay.runB(legB.0) }
      group.addTask { await machine.run(legB.1) }
      group.addTask { await serveEcho(machine) }
      let exec = await caller.startExec(makeStart(execID(1)))
      group.addTask {
        try? await exec.sendStdin(payload)
        await exec.closeStdin()
      }
      let collected = try await collect(exec)
      #expect(collected.stdout == payload)
      #expect(collected.exit == .exited(code: 0))
      group.cancelAll()
    }
  }

  @Test(arguments: [true, false])
  func singleLegBlipsHealEndToEnd(blipCallerLeg: Bool) async throws {
    var rng = SplitMix64(seed: blipCallerLeg ? 0xCA11 : 0x3A01)
    let stdinPayload = randomBytes(4000, using: &rng)
    let stdinChunks = randomChunks(of: stdinPayload, maxChunk: 300, using: &rng)
    let caller = ChannelEndpoint()
    let machine = ChannelEndpoint()
    let relay = Relay()
    let stdinLog = Box<[ExecID: [UInt8]]>([:])
    let budgets = [17, 43, 71]
    let blipped: ChannelEndpoint = blipCallerLeg ? caller : machine
    let healthy: ChannelEndpoint = blipCallerLeg ? machine : caller
    let blippedRelayLeg: @Sendable (InMemoryTransport) async -> Void
    let healthyRelayLeg: @Sendable (InMemoryTransport) async -> Void
    if blipCallerLeg {
      blippedRelayLeg = { await relay.runA($0) }
      healthyRelayLeg = { await relay.runB($0) }
    } else {
      blippedRelayLeg = { await relay.runB($0) }
      healthyRelayLeg = { await relay.runA($0) }
    }
    try await withThrowingTaskGroup(of: Void.self) { group in
      group.addTask {
        // Blipped leg: rebind through the budgets, then stay healthy.
        for budget in budgets {
          let (endpointSide, relaySide) = InMemoryTransport.pair(severAfterSends: budget)
          async let endpointRun: Void = blipped.run(endpointSide)
          async let relayRun: Void = blippedRelayLeg(relaySide)
          _ = await (endpointRun, relayRun)
        }
        let (endpointSide, relaySide) = InMemoryTransport.pair()
        async let endpointRun: Void = blipped.run(endpointSide)
        async let relayRun: Void = blippedRelayLeg(relaySide)
        _ = await (endpointRun, relayRun)
      }
      group.addTask {
        // Healthy leg: bound once, never severed.
        let (endpointSide, relaySide) = InMemoryTransport.pair()
        async let endpointRun: Void = healthy.run(endpointSide)
        async let relayRun: Void = healthyRelayLeg(relaySide)
        _ = await (endpointRun, relayRun)
      }
      group.addTask { await serveEcho(machine, stdinLog: stdinLog) }
      let exec = await caller.startExec(makeStart(execID(1), window: 512))
      group.addTask {
        for chunk in stdinChunks {
          try? await exec.sendStdin(chunk)
        }
        await exec.closeStdin()
      }
      let collected = try await collect(exec)
      #expect(collected.stdout == stdinPayload)
      #expect(collected.exit == .exited(code: 0))
      #expect(stdinLog.value == [execID(1): stdinPayload])
      group.cancelAll()
    }
  }

  @Test func relayRestartIsADoubleBlipTheStreamSurvives() async throws {
    var rng = SplitMix64(seed: 0xD0B1)
    let stdinPayload = randomBytes(3000, using: &rng)
    let caller = ChannelEndpoint()
    let machine = ChannelEndpoint()
    let stdinLog = Box<[ExecID: [UInt8]]>([:])
    let firstOutputSeen = Checkpoint()
    let restartDone = Checkpoint()
    try await withThrowingTaskGroup(of: Void.self) { group in
      let relay1 = Relay()
      let legA1 = InMemoryTransport.pair()
      let legB1 = InMemoryTransport.pair()
      group.addTask { await caller.run(legA1.0) }
      group.addTask { await relay1.runA(legA1.1) }
      group.addTask { await relay1.runB(legB1.0) }
      group.addTask { await machine.run(legB1.1) }
      group.addTask { await serveEcho(machine, stdinLog: stdinLog) }

      let exec = await caller.startExec(makeStart(execID(1), window: 256))
      group.addTask {
        try? await exec.sendStdin(stdinPayload)
        await exec.closeStdin()
      }
      group.addTask {
        await firstOutputSeen.wait()
        // Relay restart: both legs drop, a fresh relay comes up, both re-dial.
        legA1.0.sever()
        legB1.0.sever()
        restartDone.signal()
      }
      group.addTask {
        await restartDone.wait()
        let relay2 = Relay()
        let legA2 = InMemoryTransport.pair()
        let legB2 = InMemoryTransport.pair()
        await withTaskGroup(of: Void.self) { rebind in
          rebind.addTask { await caller.run(legA2.0) }
          rebind.addTask { await relay2.runA(legA2.1) }
          rebind.addTask { await relay2.runB(legB2.0) }
          rebind.addTask { await machine.run(legB2.1) }
          await rebind.waitForAll()
        }
      }

      var collected = CollectedExec()
      var merged = 0
      var signaled = false
      for try await event in exec.events {
        switch event {
        case let .output(_, cursor, data):
          #expect(cursor == merged)
          merged += data.count
          collected.stdout += data.bytes
          if !signaled {
            signaled = true
            firstOutputSeen.signal()
          }
        case let .exit(status):
          collected.exit = status
        default:
          break
        }
      }
      #expect(collected.stdout == stdinPayload)
      #expect(collected.exit == .exited(code: 0))
      #expect(stdinLog.value == [execID(1): stdinPayload])
      group.cancelAll()
    }
  }

  @Test func execStartLostToAMachineLegOutageIsRetransmittedOnHello() async throws {
    let caller = ChannelEndpoint()
    let machine = ChannelEndpoint()
    let payload = Array("resent start".utf8)
    let toMachine = Box<InMemoryTransport?>(nil)
    let dropped = Box(0)
    try await withThrowingTaskGroup(of: Void.self) { group in
      let legA = InMemoryTransport.pair()
      group.addTask { await caller.run(legA.0) }
      group.addTask {
        // Relay caller->machine pump: with the machine leg absent, frames are
        // counted and dropped, exactly like a stateless relay with a dead leg.
        for await frame in legA.1.inbound {
          if let destination = toMachine.value {
            try? await destination.send(frame)
          } else {
            dropped.update { $0 += 1 }
          }
        }
      }
      group.addTask { await serveEcho(machine) }

      let exec = await caller.startExec(makeStart(execID(1)))
      group.addTask {
        try? await exec.sendStdin(payload)
        await exec.closeStdin()
      }
      // The caller's hello, exec-start, stdin, and stdin-eof all hit the dead
      // leg; the caller's own binding never blips.
      while dropped.value < 4 {
        await Task.yield()
      }

      let legB = InMemoryTransport.pair()
      toMachine.update { $0 = legB.0 }
      group.addTask { await machine.run(legB.1) }
      group.addTask {
        for await frame in legB.0.inbound {
          try? await legA.1.send(frame)
        }
      }
      let collected = try await collect(exec)
      #expect(collected.stdout == payload)
      #expect(collected.exit == .exited(code: 0))
      group.cancelAll()
    }
  }
}
