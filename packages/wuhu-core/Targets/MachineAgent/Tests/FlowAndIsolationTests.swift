import Foundation
@testable import MachineAgent
import MachineChannel
import MachineContract
import Scratch
import Testing

@Suite
struct FlowAndIsolationTests {
  @Test func fullWindowStopsTheChildUntilTheConsumerAcks() async throws {
    try await Harness().run { h in
      let (maybeTap, _) = h.connect(tapAgentSide: true)
      let tap = try #require(maybeTap)
      let window = 1024
      let exec = await h.caller.startExec(makeStart(execID(1), command: ["yes"], window: window))
      #expect(try await pollUntil { tap.outputBytes() == window })
      // No acks are flowing: the un-acked window is full, the agent has stopped
      // reading the pipe, and `yes` is blocked on write.
      try await pollStays { tap.outputBytes() == window }
      var iterator = exec.events.makeAsyncIterator()
      var consumed = 0
      while consumed < window, let event = try await iterator.next() {
        if case let .output(_, _, data) = event { consumed += data.count }
      }
      #expect(try await pollUntil { tap.outputBytes() > window })
      await exec.kill()
      while let event = try await iterator.next() {
        if case .exit = event { break }
      }
    }
  }

  @Test func stuckAndSpewingExecsDoNotDelayOthers() async throws {
    let scratch = try ScratchFolder("machine-agent-tests")
    defer { scratch.remove() }
    let root = scratch.path
    try await Harness().run { h in
      h.connect()
      let stuck = await h.caller.startExec(makeStart(execID(1), command: ["sleep", "60"]))
      let spewing = await h.caller.startExec(makeStart(execID(2), command: ["yes"], window: 1024))
      _ = try await retryingUntilBound {
        try await h.caller.vfs(.write(path: root + "/alive.txt", data: Base64Data(Array("ok".utf8)), ifMatch: nil))
      }
      guard case .file = try await h.caller.vfs(.read(path: root + "/alive.txt")) else {
        Issue.record("vfs starved by stuck/spewing execs")
        return
      }
      let second = await h.caller.startExec(makeStart(execID(3), command: ["echo", "responsive"]))
      let collected = try await collect(second)
      #expect(collected.stdoutText == "responsive\n")
      #expect(collected.exit == .exited(code: 0))
      await stuck.kill()
      await spewing.kill()
    }
  }
}

private func pollStays(attempts: Int = 10, _ condition: @Sendable () async throws -> Bool) async throws {
  for _ in 0 ..< attempts {
    #expect(try await condition())
    await Task.yield()
  }
}
