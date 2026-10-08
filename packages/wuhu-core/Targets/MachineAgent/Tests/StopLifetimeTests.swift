import Dependencies
import Foundation
import MachineChannel
import MachineContract
import Testing

@Suite(.timeLimit(.minutes(1)))
struct StopLifetimeTests {
  @Test func outputBudgetDropsItsAllowedSuffixWhenTheUnreadWindowFills() async throws {
    try await Harness(killGrace: .milliseconds(50)).run { h in
      let (maybeTap, _) = h.connect(tapAgentSide: true)
      let tap = try #require(maybeTap)
      let exec = await h.caller.startExec(makeStart(execID(706), command: ["sh", "-c", "printf abc; sleep 10"], window: 1, maxOutput: 2))
      #expect(try await pollUntil(attempts: 50) { tap.sent.value.contains { $0.opcode == .execExit } })
      let exit = try #require(tap.sent.value.first { $0.opcode == .execExit }).payload(ExecExit.self)
      #expect(tap.outputBytes() == 1)
      #expect(exit.cursor == 1)
      #expect(exit.outputCut == true)
      #expect(exit.status == .signaled(signal: 15))
      let result = try await collect(exec)
      #expect(result.stdoutText == "a")
      #expect(result.exit == exit.status)
    }
  }

  @Test func closedOutputDoesNotCancelTimeoutOrEscalation() async throws {
    try await Harness(killGrace: .milliseconds(50)).run { h in
      h.connect()
      let began = ContinuousClock.now
      let exec = await h.caller.startExec(makeStart(execID(701), command: ["sh", "-c", "trap '' TERM; exec 1>&- 2>&-; sleep 10"], timeout: 0.2))
      let result = try await collect(exec)
      #expect(result.exit == .signaled(signal: 9))
      #expect(began.duration(to: .now) < .seconds(2))
    }
  }

  @Test func explicitKillStillWorksAfterPipesClose() async throws {
    try await Harness(killGrace: .milliseconds(50)).run { h in
      h.connect()
      let exec = await h.caller.startExec(makeStart(execID(702), command: ["sh", "-c", "echo ready; exec 1>&- 2>&-; sleep 10"]))
      var events = exec.events.makeAsyncIterator()
      #expect(try await events.next() != nil)
      @Dependency(\.continuousClock) var clock
      try await clock.sleep(for: .milliseconds(100))
      await exec.kill()
      while let event = try await events.next() {
        if case let .exit(status) = event { #expect(status == .signaled(signal: 15)) }
      }
    }
  }

  @Test(arguments: [false, true], [false, true])
  func fullUnreadWindowDoesNotBlockKillOrTimeout(timeout: Bool, trapsTERM: Bool) async throws {
    try await Harness(killGrace: .milliseconds(50)).run { h in
      let (maybeTap, _) = h.connect(tapAgentSide: true)
      let tap = try #require(maybeTap)
      let command = trapsTERM ? ["sh", "-c", "trap '' TERM; exec yes"] : ["yes"]
      let exec = await h.caller.startExec(makeStart(execID(703), command: command, window: 1024, timeout: timeout ? 0.2 : nil))
      #expect(try await pollUntil { tap.outputBytes() == 1024 })
      let began = ContinuousClock.now
      if !timeout { await exec.kill() }
      #expect(try await pollUntil(attempts: 50) { tap.sent.value.contains { $0.opcode == .execExit } })
      #expect(began.duration(to: .now) < .seconds(1))
      let exit = try #require(tap.sent.value.first { $0.opcode == .execExit }).payload(ExecExit.self)
      #expect(exit.status == .signaled(signal: trapsTERM ? 9 : 15))
      #expect(exit.outputCut == true)
      #expect(exit.cursor == 1024)
      let result = try await collect(exec)
      #expect(result.exit != nil)
    }
  }

  @Test func escalationStillKillsDescendantsAfterTheLeaderExitsOnTERM() async throws {
    try await Harness(killGrace: .milliseconds(50)).run { h in
      h.connect()
      let marker = h.stateDirectory + "/survived"
      let command = "sh -c 'trap \"\" TERM; echo ready; sleep 1; echo survived > \"\(marker)\"' & wait"
      let exec = await h.caller.startExec(makeStart(execID(705), command: ["sh", "-c", command]))
      var events = exec.events.makeAsyncIterator()
      #expect(try await events.next() != nil)
      await exec.kill()
      while let event = try await events.next() {
        if case let .exit(status) = event { #expect(status == .signaled(signal: 15)) }
      }
      @Dependency(\.continuousClock) var clock
      try await clock.sleep(for: .milliseconds(1200))
      #expect(!FileManager.default.fileExists(atPath: marker))
    }
  }

  @Test func directChildExitStillUnblocksInheritedPipes() async throws {
    try await Harness().run { h in
      h.connect()
      let began = ContinuousClock.now
      let exec = await h.caller.startExec(makeStart(execID(704), command: ["sh", "-c", "sleep 2 & exit 0"]))
      let result = try await collect(exec)
      #expect(result.exit == .exited(code: 0))
      #expect(began.duration(to: .now) < .seconds(1))
    }
  }
}
