import Foundation
@testable import MachineAgent
import MachineChannel
import MachineContract
import Testing

private func firstOutputLine(_ exec: OutgoingExec) async throws -> (line: String, events: ExecEvents.Iterator) {
  var iterator = exec.events.makeAsyncIterator()
  var buffer: [UInt8] = []
  while let event = try await iterator.next() {
    if case let .output(_, _, data) = event {
      buffer += data.bytes
      if let newline = buffer.firstIndex(of: UInt8(ascii: "\n")) {
        return (String(decoding: buffer[..<newline], as: UTF8.self), iterator)
      }
    }
  }
  throw ChannelError.protocolViolation("no output line")
}

private func awaitExit(_ iterator: inout ExecEvents.Iterator) async throws -> MachineContract.ExitStatus? {
  while let event = try await iterator.next() {
    if case let .exit(status) = event { return status }
  }
  return nil
}

@Suite
struct KillTests {
  @Test func killTakesDownTheWholeProcessGroup() async throws {
    try await Harness().run { h in
      h.connect()
      let exec = await h.caller.startExec(makeStart(execID(1), command: ["sh", "-c", "sleep 60 & echo $!; wait"]))
      var (line, iterator) = try await firstOutputLine(exec)
      let grandchild = try #require(Int32(line))
      #expect(processAlive(grandchild))
      await exec.kill()
      let status = try await awaitExit(&iterator)
      #expect(status == .signaled(signal: 15))
      #expect(try await pollUntil { !processAlive(grandchild) })
    }
  }

  @Test func termTrappingChildIsKilledAfterTheGrace() async throws {
    try await Harness(killGrace: .milliseconds(150)).run { h in
      h.connect()
      let exec = await h.caller.startExec(makeStart(
        execID(1),
        command: ["sh", "-c", "trap '' TERM; echo ready; while :; do sleep 0.1; done"],
      ))
      var (line, iterator) = try await firstOutputLine(exec)
      #expect(line == "ready")
      await exec.kill()
      let status = try await awaitExit(&iterator)
      #expect(status == .signaled(signal: 9))
    }
  }

  @Test func timeoutKillsTheGroup() async throws {
    try await Harness().run { h in
      h.connect()
      let exec = await h.caller.startExec(makeStart(execID(1), command: ["sleep", "30"], timeout: 0.2))
      let collected = try await collect(exec)
      #expect(collected.exit == .signaled(signal: 15))
    }
  }

  @Test func aTimeoutPastAnyClockIsClamped() async throws {
    try await Harness().run { h in
      h.connect()
      let exec = await h.caller.startExec(makeStart(execID(1), command: ["sh", "-c", "echo ok"], timeout: 1e300))
      let collected = try await collect(exec)
      #expect(String(decoding: collected.stdout, as: UTF8.self) == "ok\n")
      #expect(collected.exit == .exited(code: 0))
    }
  }

  @Test func maxOutputClampsExactlyAndKills() async throws {
    try await Harness().run { h in
      h.connect()
      let exec = await h.caller.startExec(makeStart(execID(1), command: ["yes"], maxOutput: 1000))
      let collected = try await collect(exec)
      #expect(collected.stdout.count == 1000)
      guard case .signaled = collected.exit else {
        Issue.record("expected signaled exit, got \(String(describing: collected.exit))")
        return
      }
    }
  }
}
