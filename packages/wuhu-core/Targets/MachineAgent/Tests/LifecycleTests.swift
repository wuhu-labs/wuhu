import Clocks
import ClockTesting
import Dependencies
import Foundation
@testable import MachineAgent
import MachineChannel
import MachineContract
import Scratch
import Testing

// Advances the injected TestClock while polling a real-world condition (a child
// process dying), giving the agent's clock-driven grace a chance to arm and
// fire between real-time waits.
private func pollUntilAdvancing(
  clock: TestClock<Duration>,
  by step: Duration,
  attempts: Int = 200,
  _ condition: @Sendable () -> Bool,
) async throws -> Bool {
  let realClock = ContinuousClock()
  for _ in 0 ..< attempts {
    if condition() { return true }
    await clock.advance(by: step)
    try await realClock.sleep(for: .milliseconds(20))
  }
  return condition()
}

@Suite(.timeLimit(.minutes(2)))
struct LifecycleTests {
  /// Runs on a `VirtualClock`: time moves only from one pending sleep to the next, so the dial instants are the backoff schedule
  /// itself, however slow the host is.
  @Test func reconnectLoopBacksOffOnTheInjectedClock() async throws {
    let clock = VirtualClock()
    let scratch = try ScratchFolder("machine-agent-tests")
    defer { scratch.remove() }
    let agent = withDependencies {
      $0.continuousClock = AnyClock(clock)
    } operation: {
      MachineAgent(stateDirectory: scratch.path)
    }
    let caller = ChannelEndpoint()
    let dials = Box<[Duration]>([])
    let (callerFeed, callerContinuation) = AsyncStream<InMemoryTransport>.makeStream()
    let (connected, connectedContinuation) = AsyncStream<Void>.makeStream()
    try await withThrowingTaskGroup(of: Void.self) { group in
      group.addTask {
        await agent.run { @Sendable in
          let attempt = dials.update { dials in
            dials.append(clock.now.offset)
            return dials.count
          }
          guard attempt > 3 else { throw ChannelError.severed }
          let (a, b) = InMemoryTransport.pair()
          callerContinuation.yield(b)
          connectedContinuation.finish()
          return a
        }
      }
      group.addTask {
        for await transport in callerFeed {
          await caller.run(transport)
        }
      }
      group.addTask {
        // 1s + 2s + 4s of backoff before the fourth (successful) dial; time cannot pass 7s, so a dial off the schedule shows.
        try await clock.run(through: VirtualClock.at(.seconds(7))) {
          for await _ in connected {}
        }
        #expect(dials.value == [.zero, .seconds(1), .seconds(3), .seconds(7)])
        let exec = await caller.startExec(makeStart(execID(1), command: ["echo", "reconnected"]))
        let collected = try await collect(exec)
        #expect(collected.stdoutText == "reconnected\n")
      }
      try await group.next()
      group.cancelAll()
    }
  }

  @Test func disconnectionPastGraceKillsLiveExecGroups() async throws {
    let clock = TestClock()
    let harness = try withDependencies {
      $0.continuousClock = AnyClock(clock)
    } operation: {
      try Harness()
    }
    try await harness.run { h in
      let (_, transport) = h.connect()
      let exec = await h.caller.startExec(makeStart(execID(1), command: ["sh", "-c", "sleep 600 & echo $!; wait"]))
      var iterator = exec.events.makeAsyncIterator()
      var pid: Int32?
      while pid == nil, let event = try await iterator.next() {
        if case let .output(_, _, data) = event {
          pid = Int32(String(decoding: data.bytes, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
        }
      }
      let child = try #require(pid)
      #expect(processAlive(child))
      transport.sever()
      // Advance past the disconnect grace repeatedly: the grace sleep is armed
      // only once dialRacingGrace runs after the unbind, so keep advancing (on
      // the TestClock) until the group is actually reaped.
      let dead = try await pollUntilAdvancing(clock: clock, by: .seconds(310)) { !processAlive(child) }
      #expect(dead)
    }
  }

  @Test func blipMidExecHealsByteExact() async throws {
    try await Harness().run { h in
      let (_, transport) = h.connect()
      let exec = await h.caller.startExec(makeStart(execID(1), command: ["cat"]))
      var rng = SplitMix64(seed: 42)
      let payload = (0 ..< 8192).map { _ in UInt8.random(in: 32 ... 126, using: &rng) }
      let chunks = stride(from: 0, to: payload.count, by: 512).map { Array(payload[$0 ..< min($0 + 512, payload.count)]) }
      for (index, chunk) in chunks.enumerated() {
        if index == chunks.count / 2 {
          transport.sever()
          h.connect()
        }
        try await exec.sendStdin(chunk)
      }
      await exec.closeStdin()
      let collected = try await collect(exec)
      #expect(collected.stdout == payload)
      #expect(collected.exit == .exited(code: 0))
    }
  }
}

extension Box<Int> {
  fileprivate func increment() -> Int {
    update { value in
      value += 1
      return value
    }
  }
}
