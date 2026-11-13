import ControlledTime
import Dependencies
#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import GRDB
import JSONValue
@testable import LoopCore
import Scratch
import SessionDomain
@testable import SpaceCore
import Testing
import WuhuAI

/// Cache warming as the session cell keeps it: the reply's schedule arms a wake, the wake is a ping, and everything that can end warming does.
@Suite struct WarmingTests {
  private func turn(_ space: Space, _ id: SessionID) -> SessionTurn? {
    space.worker.cell(SessionCell.ID(id.rawValue)).turn()
  }

  private func notices(_ space: Space, _ id: SessionID) async throws -> [TranscriptLine] {
    try await space.sessions.lines(id).filter { $0.key == LineKey.cacheWarming }
  }

  /// Whether the cell has taken the delayed put on `topic`: its due is recorded from then on, while it is still ahead.
  private func delayedArmed(_ space: Space, _ id: SessionID, topic: String) async throws -> Bool {
    try await space.writer.read { db in
      try String.fetchOne(
        db,
        sql: "SELECT due_at FROM session_queue WHERE session_id = ? AND topic = ? ORDER BY id DESC LIMIT 1",
        arguments: [id.rawValue, topic],
      ) != nil
    }
  }

  private func agent(_ space: Space) async throws -> SessionID {
    try await space.sessions.createSession(group: .shared, title: "warm", kind: .agent, createdBy: "morgan", model: .test)
  }

  /// Waits until the cell's warming wake is the pending sleep, then moves the clock past it: a wake armed after the advance would count from the new now and never fire.
  private func waking(_ time: TimeControl, _ space: Space, _ id: SessionID, _ description: String) async throws {
    let interval = Double(try #require(turn(space, id)?.warming?.schedule.intervalSeconds))
    try await time.asleep(description, dueIn: interval)
    await time.advance(by: interval)
  }

  @Test func aSpaceAtThePreviousSessionSchemaGainsTheWarmingColumn() async throws {
    try await withKernelDeps { _ in
      let folder = try ScratchFolder("session-schema")
      let file = folder.url.appending(path: "space.sqlite")
      let first = try Space.open(file: file)
      let execution = SessionExecution(space: first, loopConfig: makeConfig())
      execution.start()
      await execution.shutdown()
      try await first.close()
      try await DatabaseQueue(path: file.path).write { db in
        try db.execute(sql: "DROP TABLE session_scripts")
        try db.execute(sql: "ALTER TABLE session_state DROP COLUMN warming")
        try db.execute(sql: "UPDATE wuwei_schema SET applied = applied - 2 WHERE kind = 'SessionCell'")
      }

      let space = try Space.open(file: file)
      let upgraded = SessionExecution(space: space, loopConfig: makeConfig())
      let id = try await space.sessions.createSession(group: .shared, title: "upgraded", kind: .agent, createdBy: "morgan", model: .test)
      upgraded.start()
      #expect(try await space.sessions.record(id).title == "upgraded")
      await upgraded.shutdown()
      let columns = try await DatabaseQueue(path: file.path).read { db in try String.fetchAll(db, sql: "SELECT name FROM pragma_table_info('session_state')") }
      #expect(columns.contains("warming"))
      try await space.close()
    }
  }

  @Test func aReplyWithAPolicyArmsTheWakeAndThePingIsAnInference() async throws {
    try await withKernelDeps { time in
      let space = try Space.inMemory()
      let schedule = WarmingSchedule(intervalSeconds: 10, lifetimeSeconds: 100, maxPings: 5)
      let script = InferenceScript([Fix.replying("hi", warming: schedule), Fix.replying("still here", warming: schedule)])
      let config = makeConfig(inference: { try await script($0) })
      let service = SessionExecution(space: space, loopConfig: config)
      let id = try await agent(space)
      try await runService(service) { execution in
        try await execution.enqueue(item: Fix.message("hello"), to: id)
        try await until("the reply") { script.count == 1 }
        try await until("warming is armed") { turn(space, id)?.warming != nil }
        #expect(turn(space, id)?.warming?.pings == 0)
        #expect(try await notices(space, id).isEmpty)

        try await waking(time, space, id, "the warming wake")
        try await until("the ping") { script.count == 2 }
        #expect(script.attempts.value[1].ping)
        try await until("the ping is answered") { turn(space, id)?.turn == .idle }
        #expect(turn(space, id)?.warming?.pings == 1)
        #expect(try await notices(space, id).count == 1)
        #expect(try await notices(space, id).last?.text.contains("<cache-warming-notice>") == true)
        #expect(try await space.sessions.lines(id).last?.role == .assistant)
      }
    }
  }

  @Test func aReplyWithoutAPolicyLeavesNoWake() async throws {
    try await withKernelDeps { time in
      let space = try Space.inMemory()
      let script = InferenceScript([Fix.replying("hi")])
      let config = makeConfig(inference: { try await script($0) })
      let service = SessionExecution(space: space, loopConfig: config)
      let id = try await agent(space)
      try await runService(service) { execution in
        try await execution.enqueue(item: Fix.message("hello"), to: id)
        try await until("the reply is answered") { script.count == 1 && turn(space, id)?.turn == .idle }
        #expect(turn(space, id)?.warming == nil)
        await time.advance(by: 10000)
        try await holds("no ping") { script.count == 1 }
      }
    }
  }

  @Test func maxPingsEndsWarming() async throws {
    try await withKernelDeps { time in
      let space = try Space.inMemory()
      let schedule = WarmingSchedule(intervalSeconds: 10, lifetimeSeconds: 100, maxPings: 2)
      let script = InferenceScript([
        Fix.replying("hi", warming: schedule),
        Fix.replying("one", warming: schedule),
        Fix.replying("two", warming: schedule),
      ])
      let config = makeConfig(inference: { try await script($0) })
      let service = SessionExecution(space: space, loopConfig: config)
      let id = try await agent(space)
      try await runService(service) { execution in
        try await execution.enqueue(item: Fix.message("hello"), to: id)
        try await until("the reply") { script.count == 1 }
        try await until("warming is armed") { turn(space, id)?.warming != nil }

        try await waking(time, space, id, "the first warming wake")
        try await until("the first ping") { script.count == 2 }
        try await until("the first ping is answered") { turn(space, id)?.turn == .idle }

        try await waking(time, space, id, "the second warming wake")
        try await until("the second ping") { script.count == 3 }
        try await until("both pings are answered") { turn(space, id)?.turn == .idle }
        #expect(turn(space, id)?.warming?.pings == 2)

        try await waking(time, space, id, "the warming wake past the pings")
        try await until("warming ends") { turn(space, id)?.warming == nil }
        try await holds("no third ping") { script.count == 3 }
        #expect(try await notices(space, id).count == 2)
      }
    }
  }

  @Test func aRealInputResetsTheCountAndAPingsReplyDoesNot() async throws {
    try await withKernelDeps { time in
      let space = try Space.inMemory()
      let schedule = WarmingSchedule(intervalSeconds: 10, lifetimeSeconds: 100, maxPings: 5)
      let script = InferenceScript([
        Fix.replying("hi", warming: schedule),
        Fix.replying("one", warming: schedule),
        Fix.replying("answer", warming: schedule),
      ])
      let config = makeConfig(inference: { try await script($0) })
      let service = SessionExecution(space: space, loopConfig: config)
      let id = try await agent(space)
      try await runService(service) { execution in
        try await execution.enqueue(item: Fix.message("hello"), to: id)
        try await until("the reply") { script.count == 1 }
        try await until("warming is armed") { turn(space, id)?.warming != nil }

        try await waking(time, space, id, "the warming wake")
        try await until("the ping") { script.count == 2 }
        try await until("the ping is answered") { turn(space, id)?.turn == .idle }
        #expect(turn(space, id)?.warming?.pings == 1)

        try await execution.enqueue(item: Fix.message("more", message: "m2"), to: id)
        try await until("the reply to real input") { script.count == 3 }
        try await until("the answer") { turn(space, id)?.turn == .idle }
        #expect(turn(space, id)?.warming?.pings == 0)
      }
    }
  }

  /// The production shape: an interval past wuwei's 30 s `cellIdle`, so the cell is evicted before its wake. The scan brings it back, and the pin is spent once.
  @Test func aWakePastTheCellIdleIsBroughtBackByTheScanAndPingsOnce() async throws {
    try await withKernelDeps { time in
      let space = try Space.inMemory()
      let schedule = WarmingSchedule(intervalSeconds: 100, lifetimeSeconds: 1000, maxPings: 5)
      let script = InferenceScript([Fix.replying("hi", warming: schedule), Fix.replying("still here", warming: schedule)])
      let config = makeConfig(inference: { try await script($0) })
      let service = SessionExecution(space: space, loopConfig: config)
      let id = try await agent(space)
      try await runService(service) { execution in
        try await execution.enqueue(item: Fix.message("hello"), to: id)
        try await until("the reply") { script.count == 1 }
        try await until("warming is armed") { turn(space, id)?.warming != nil }

        for _ in 0 ..< 130 where script.count == 1 { await time.advance(by: 1) }
        try await until("the ping") { script.count == 2 }
        #expect(script.attempts.value[1].ping)
        try await holds("exactly one ping") { script.count == 2 }
        #expect(try await notices(space, id).count == 1)
      }
    }
  }

  @Test func aWakePastTheLifetimeEndsWarmingWithoutAnInference() async throws {
    try await withKernelDeps { time in
      let space = try Space.inMemory()
      let schedule = WarmingSchedule(intervalSeconds: 10, lifetimeSeconds: 15, maxPings: 10)
      let script = InferenceScript([Fix.replying("hi", warming: schedule)])
      let config = makeConfig(inference: { try await script($0) })
      let first = SessionExecution(space: space, loopConfig: config)
      let id = try await agent(space)
      first.start()
      try await first.enqueue(item: Fix.message("hello"), to: id)
      try await until("the reply") { script.count == 1 }
      try await until("warming is armed") { turn(space, id)?.warming != nil }

      await first.shutdown()
      await time.advance(by: 400)
      let second = SessionExecution(space: space, loopConfig: config)
      second.start()
      try await until("warming ends") {
        await time.advance(by: 1)
        return turn(space, id)?.warming == nil
      }
      try await holds("no inference past the lifetime") { script.count == 1 }
      await second.shutdown()
    }
  }

  @Test func aHeldSessionIsNotPinged() async throws {
    try await withKernelDeps { time in
      let space = try Space.inMemory()
      let schedule = WarmingSchedule(intervalSeconds: 10, lifetimeSeconds: 100, maxPings: 5)
      let script = InferenceScript([Fix.replying("hi", warming: schedule)])
      let config = makeConfig(inference: { try await script($0) })
      let service = SessionExecution(space: space, loopConfig: config)
      let id = try await agent(space)
      try await runService(service) { execution in
        try await execution.enqueue(item: Fix.message("hello"), to: id)
        try await until("the reply") { script.count == 1 }
        try await until("warming is armed") { turn(space, id)?.warming != nil }
        try await space.sessions.markInterrupted(id)

        try await waking(time, space, id, "the warming wake")
        try await until("warming ends") { turn(space, id)?.warming == nil }
        try await holds("no ping") { script.count == 1 }
      }
    }
  }

  @Test func aFailedPingEndsWarmingAndTheSessionTakesTheNextInput() async throws {
    try await withKernelDeps { time in
      let space = try Space.inMemory()
      let schedule = WarmingSchedule(intervalSeconds: 10, lifetimeSeconds: 100, maxPings: 5)
      let script = InferenceScript([
        Fix.replying("hi", warming: schedule),
        Fix.failing(.rateLimited(retryAt: nil)),
        Fix.replying("after"),
      ])
      let config = makeConfig(inference: { try await script($0) })
      let service = SessionExecution(space: space, loopConfig: config)
      let id = try await agent(space)
      try await runService(service) { execution in
        try await execution.enqueue(item: Fix.message("hello"), to: id)
        try await until("the reply") { script.count == 1 }
        try await until("warming is armed") { turn(space, id)?.warming != nil }

        try await waking(time, space, id, "the warming wake")
        try await until("the ping fails") { script.count == 2 }
        try await until("the session is idle again") { turn(space, id)?.warming == nil && turn(space, id)?.turn == .idle }
        #expect(script.attempts.value[1].ping)
        #expect(try await space.sessions.record(id).work == .noWork)
        #expect(try await space.sessions.record(id).errorMessage == nil)
        #expect(try await space.sessions.lines(id).last?.key == LineKey.cacheWarming)

        try await execution.enqueue(item: Fix.message("more", message: "m2"), to: id)
        try await until("the next input is answered") { script.count == 3 }
        try await until("its reply") { try await space.sessions.lines(id).last?.text == "after" }
      }
    }
  }

  @Test func aPingsToolContinuationThatFailsLeavesTheToolResultsLast() async throws {
    try await withKernelDeps { time in
      let space = try Space.inMemory()
      let schedule = WarmingSchedule(intervalSeconds: 10, lifetimeSeconds: 100, maxPings: 5)
      let script = InferenceScript([
        Fix.replying("hi", warming: schedule),
        Fix.replying("looking", calls: [.init(id: "call_0", name: "read", arguments: .object([:]))], warming: schedule),
        Fix.failing(.rateLimited(retryAt: nil)),
        Fix.replying("after"),
      ])
      let exec = ExecScript { _ in .exec(.init(output: "ok", exitCode: 0)) }
      let config = makeConfig(executeTool: { try await exec($0) }, inference: { try await script($0) })
      let service = SessionExecution(space: space, loopConfig: config)
      let id = try await agent(space)
      try await runService(service) { execution in
        try await execution.enqueue(item: Fix.message("hello"), to: id)
        try await until("the reply") { script.count == 1 }
        try await until("warming is armed") { turn(space, id)?.warming != nil }

        try await waking(time, space, id, "the warming wake")
        try await until("the pings continuation fails") { script.count == 3 }
        try await until("the session is idle again") { turn(space, id)?.warming == nil && turn(space, id)?.turn == .idle }
        #expect(script.attempts.value[2].ping)
        #expect(exec.calls.value.count == 1)
        let lines = try await space.sessions.lines(id)
        #expect(lines.last?.role == .toolResult)
        #expect(lines.last?.text == "ok")
        #expect(try await space.sessions.record(id).errorMessage == nil)

        try await execution.enqueue(item: Fix.message("more", message: "m2"), to: id)
        try await until("the next input is answered") { script.count == 4 }
        try await until("its reply") { try await space.sessions.lines(id).last?.text == "after" }
      }
    }
  }

  /// A ping still in flight when its next interval passes must not spend a second ping: its reply re-anchors the wake.
  @Test func aPingInFlightAcrossItsDeadlineSpendsNothingMore() async throws {
    try await withKernelDeps { time in
      let space = try Space.inMemory()
      let schedule = WarmingSchedule(intervalSeconds: 10, lifetimeSeconds: 1000, maxPings: 1)
      let gate = Latch()
      let script = InferenceScript([
        Fix.replying("hi", warming: schedule),
        { _ in
          await gate.wait(unless: { Task.isCancelled })
          return Fix.reply("pinged", warming: schedule)
        },
      ])
      let config = makeConfig(inference: { try await script($0) })
      let service = SessionExecution(space: space, loopConfig: config)
      let id = try await agent(space)
      try await runService(service) { execution in
        try await execution.enqueue(item: Fix.message("hello"), to: id)
        try await until("the reply") { script.count == 1 }
        try await until("warming is armed") { turn(space, id)?.warming != nil }

        try await waking(time, space, id, "the warming wake")
        try await until("the ping starts") { script.count == 2 }
        #expect(turn(space, id)?.warming?.pings == 1)

        await time.advance(by: 20)
        try await holds("no second ping while the first is in flight") { script.count == 2 }

        gate.release()
        try await until("the ping is answered") { turn(space, id)?.turn == .idle }
        #expect(turn(space, id)?.warming?.pings == 1)

        await time.advance(by: 20)
        try await until("warming ends") { turn(space, id)?.warming == nil }
        try await holds("no second ping") { script.count == 2 }
        #expect(try await notices(space, id).count == 1)
      }
    }
  }

  /// A mechanical fold keeps the ping's budget and its origin, so the continuation after it is still the ping's.
  @Test func aPingsReplyThatCompactsKeepsItsBudget() async throws {
    try await withKernelDeps { time in
      let space = try Space.inMemory()
      let schedule = WarmingSchedule(intervalSeconds: 10, lifetimeSeconds: 100, maxPings: 1)
      let call = ToolCall(id: "call_c", name: "compact", arguments: .object(["summary": .string("what happened")]))
      let script = InferenceScript([
        Fix.replying("hi", warming: schedule),
        Fix.replying("folding", calls: [call], warming: schedule),
        Fix.replying("on with it", warming: schedule),
      ])
      let config = makeConfig(inference: { try await script($0) })
      let service = SessionExecution(space: space, loopConfig: config)
      let id = try await agent(space)
      try await runService(service) { execution in
        try await execution.enqueue(item: Fix.message("hello"), to: id)
        try await until("the reply") { script.count == 1 }
        try await until("warming is armed") { turn(space, id)?.warming != nil }

        try await waking(time, space, id, "the warming wake")
        try await until("the continuation after the fold") { script.count == 3 }
        try await until("its reply") { turn(space, id)?.turn == .idle }
        #expect(script.attempts.value[1].ping)
        #expect(script.attempts.value[2].ping, "the continuation after a fold is still the ping's")
        #expect(turn(space, id)?.warming?.pings == 1)
        #expect(try await space.sessions.generationState(id).generation == 1)
      }
    }
  }

  @Test func aPingsCompactedContinuationThatFailsEndsWarming() async throws {
    try await withKernelDeps { time in
      let space = try Space.inMemory()
      let schedule = WarmingSchedule(intervalSeconds: 10, lifetimeSeconds: 100, maxPings: 1)
      let call = ToolCall(id: "call_c", name: "compact", arguments: .object(["summary": .string("what happened")]))
      let script = InferenceScript([
        Fix.replying("hi", warming: schedule),
        Fix.replying("folding", calls: [call], warming: schedule),
        Fix.failing(.rateLimited(retryAt: nil)),
      ])
      let config = makeConfig(inference: { try await script($0) })
      let service = SessionExecution(space: space, loopConfig: config)
      let id = try await agent(space)
      try await runService(service) { execution in
        try await execution.enqueue(item: Fix.message("hello"), to: id)
        try await until("the reply") { script.count == 1 }
        try await until("warming is armed") { turn(space, id)?.warming != nil }

        try await waking(time, space, id, "the warming wake")
        try await until("the continuation after the fold fails") { script.count == 3 }
        try await until("the session is idle again") { turn(space, id)?.warming == nil && turn(space, id)?.turn == .idle }
        #expect(script.attempts.value[2].ping)
        #expect(try await space.sessions.record(id).errorMessage == nil)
        #expect(try await space.sessions.generationState(id).generation == 1)
      }
    }
  }

  /// Warming that ended under an outstanding ping stays ended: a withdrawn delayed input must not let that ping's reply start it again.
  @Test func aWithdrawnDelayedInputDoesNotRefillTheBudgetOfThePingItInterrupted() async throws {
    try await withKernelDeps { time in
      let space = try Space.inMemory()
      let schedule = WarmingSchedule(intervalSeconds: 10, lifetimeSeconds: 1000, maxPings: 1)
      let gate = Latch()
      let script = InferenceScript([
        Fix.replying("hi", warming: schedule),
        { _ in
          await gate.wait(unless: { Task.isCancelled })
          return Fix.reply("pinged", warming: schedule)
        },
        Fix.replying("after real input", warming: schedule),
      ])
      let config = makeConfig(inference: { try await script($0) })
      let service = SessionExecution(space: space, loopConfig: config)
      let id = try await agent(space)
      try await runService(service) { execution in
        try await execution.enqueue(item: Fix.message("hello"), to: id)
        try await until("the reply") { script.count == 1 }
        try await until("warming is armed") { turn(space, id)?.warming != nil }

        space.worker.send(SessionCell.ID(id.rawValue)).put(SessionPut(Fix.message("later", message: "m2"), topic: "t", due: Date(timeIntervalSinceReferenceDate: 15)))
        // The put is mail: wait until the cell's step has taken it, so its due is recorded while it is still ahead. A step that runs
        // after the due stores the input as due now, with no `due_at` and no wake, and the ping in flight never drains it.
        try await until("the delayed input is armed") { try await delayedArmed(space, id, topic: "t") }

        try await waking(time, space, id, "the warming wake")
        try await until("the ping starts") { script.count == 2 }

        await time.advance(by: 5)
        try await until("the delayed input's wake ends warming") { turn(space, id)?.warming == nil }
        space.worker.send(SessionCell.ID(id.rawValue)).clear("t")

        gate.release()
        try await until("the ping is answered") { turn(space, id)?.turn == .idle }
        #expect(turn(space, id)?.warming == nil)

        await time.advance(by: 20)
        try await holds("no ping beyond the budget") { script.count == 2 }
        #expect(try await notices(space, id).count == 1)

        try await execution.enqueue(item: Fix.message("real", message: "m3"), to: id)
        try await until("the reply to real input") { script.count == 3 }
        try await until("its answer") { turn(space, id)?.turn == .idle }
        #expect(turn(space, id)?.warming?.pings == 0)
      }
    }
  }

  /// The same for an automatic pointer compaction still running when the ping's next deadline passes.
  @Test func aPointerCompactionAcrossTheWarmingDeadlineDoesNotRefillThePingsBudget() async throws {
    try await withKernelDeps { time in
      let space = try Space.inMemory()
      let schedule = WarmingSchedule(intervalSeconds: 10, lifetimeSeconds: 1000, maxPings: 1)
      let gate = Latch()
      let preparing = Box(false)
      let script = InferenceScript([
        Fix.replying("hi", warming: schedule),
        Fix.replying("big turn", tokens: 900, warming: schedule),
        Fix.replying("after compaction", warming: schedule),
        Fix.replying("after real input", warming: schedule),
      ])
      var config = makeConfig(inference: { try await script($0) }, budget: ContextBudget(maxInput: 1100, maxOutput: 100))
      config.prepareCompaction = { _, _, _ in
        preparing.withLock { $0 = true }
        await gate.wait(unless: { Task.isCancelled })
        return nil
      }
      let service = SessionExecution(space: space, loopConfig: config)
      let id = try await agent(space)
      try await runService(service) { execution in
        try await execution.enqueue(item: Fix.message("hello"), to: id)
        try await until("the reply") { script.count == 1 }
        try await until("warming is armed") { turn(space, id)?.warming != nil }

        try await waking(time, space, id, "the warming wake")
        try await until("the pointer compaction starts") { preparing.value }

        await time.advance(by: 10)
        try await until("the wake under the compaction ends warming") { turn(space, id)?.warming == nil }

        gate.release()
        try await until("the continuation after the fold") { script.count == 3 }
        try await until("its reply") { turn(space, id)?.turn == .idle }
        #expect(script.attempts.value[2].ping)
        #expect(turn(space, id)?.warming == nil)
        #expect(try await space.sessions.generationState(id).generation == 1)

        await time.advance(by: 20)
        try await holds("no ping beyond the budget") { script.count == 3 }

        try await execution.enqueue(item: Fix.message("real", message: "m3"), to: id)
        try await until("the reply to real input") { script.count == 4 }
        try await until("its answer") { turn(space, id)?.turn == .idle }
        #expect(turn(space, id)?.warming?.pings == 0)
      }
    }
  }
}
