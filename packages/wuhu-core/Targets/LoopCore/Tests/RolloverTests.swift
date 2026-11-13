import ControlledTime
import Dependencies
import Foundation
import GRDB
import JSONValue
@testable import LoopCore
import Scratch
import SessionDomain
@testable import SpaceCore
import Synchronization
import Testing
import WuhuAI
import Wuwei

/// Two workers on one store, as two server processes on one database while a release rolls.
@Suite struct RolloverTests {
  private func rolling(_ body: (_ old: Space, _ new: Space, TimeControl) async throws -> Void) async throws {
    try await withKernelDeps { time in
      let folder = try ScratchFolder("rollover")
      let file = folder.url.appending(path: "space.sqlite")
      let old = try Space.open(file: file)
      let new = try Space.open(file: file)
      try await body(old, new, time)
      try await old.close()
      try await new.close()
    }
  }

  /// Waits for the session to settle on the worker that took over. One advance past the 10 s lease a copied database still carries
  /// is enough for a scan to claim it there and for every poke after; see `until` on why the clock must not move on every poll.
  private func settles(_ session: SessionID, in space: Space, _ time: TimeControl) async throws {
    await time.advance(by: 12)
    try await until("the session settles on the worker that took over") {
      try await space.sessions.settledWork(session)
    }
  }

  private func toolResults(_ session: SessionID, in space: Space) async throws -> [TranscriptLine] {
    try await space.sessions.lines(session).filter { $0.role == .toolResult }
  }

  @Test func `overlapping stops cannot release a replacement worker`() async throws {
    try await rolling { old, _, _ in
      let sid = try await old.sessions.createSession(group: .shared, title: "before", kind: .agent, createdBy: "morgan", model: .test)
      let cleanup = Latch()
      let cleaning = Box(false)
      let script = InferenceScript([{ _ in
        await Latch().wait(unless: { Task.isCancelled })
        cleaning.withLock { $0 = true }
        await cleanup.wait()
        throw CancellationError()
      }, Fix.replying("resumed")])
      let config = makeConfig(inference: { try await script($0) })
      let execution = SessionExecution(space: old, loopConfig: config)
      execution.start()
      try await execution.enqueue(item: Fix.message("hello"), to: sid)
      try await until("the request starts") { script.count == 1 }

      let simulation = Simulation(seed: 1)
      let first = simulation.spawn()
      let second = simulation.spawn()
      let stopped = Box(0)
      let entered = Box(0)
      for process in [first, second] {
        Task(executorPreference: process) {
          entered.withLock { $0 += 1 }
          await old.stopWorker()
          stopped.withLock { $0 += 1 }
        }
      }
      simulation.run(for: .zero)
      #expect(entered.value == 2)
      try await until("cancellation cleanup blocks both stops") { cleaning.value }
      simulation.freeze(second)
      cleanup.release()
      try await until("one stop completes") {
        simulation.run(for: .zero)
        return stopped.value == 1
      }
      let replacement = old.worker
      let restarted = SessionExecution(space: old, loopConfig: config)
      restarted.start()
      simulation.thaw(second)
      try await until("the older stop resumes after the restart") {
        simulation.run(for: .zero)
        return stopped.value == 2
      }
      #expect(old.worker === replacement)
      #expect(try await replacement.call(SessionCell.ID(sid.rawValue)) { _ in true })
      await restarted.shutdown()
    }
  }

  @Test func `a quiesced worker keeps the session lease until its final release`() async throws {
    try await rolling { old, new, time in
      let sid = try await old.sessions.createSession(group: .shared, title: "before", kind: .agent, createdBy: "morgan", model: .test)
      let config = makeConfig()
      let first = SessionExecution(space: old, loopConfig: config)
      let second = SessionExecution(space: new, loopConfig: config)
      let cell = SessionCell.ID(sid.rawValue)
      first.start()
      _ = try await old.worker.call(cell) { _ in true }
      second.start()
      await first.quiesce()

      _ = try await second.retitle(sid, to: "after")
      for _ in 0 ..< 15 {
        await time.advance(by: 1)
        let renewedPast = (old.worker.scheduler.now + .seconds(9)).milliseconds
        try await until("the quiesced worker renews before the next clock tick") {
          let expiry = try await old.writer.read { db in
            try Int64.fetchOne(db, sql: "SELECT expires_at FROM wuwei_addressable WHERE address = ? AND holder = ?", arguments: [cell.description, old.worker.id])
          }
          return try #require(expiry) > renewedPast
        }
      }
      #expect(new.worker.hasMail(for: cell.recipient))
      #expect(try await new.sessions.record(sid).title == "before")
      await #expect(throws: Evicted.self) {
        try await new.worker.call(cell) { _ in true }
      }

      await first.shutdown()
      await time.advance(by: 2)
      try await until("the new worker takes the released session and its mail") {
        try await new.sessions.record(sid).title == "after"
      }
      #expect(!new.worker.hasMail(for: cell.recipient))
      #expect(try await new.worker.call(cell) { _ in true })
      await second.shutdown()
    }
  }

  @Test func `a retry delay survives the roll and the new worker waits out the rest of it`() async throws {
    try await rolling { old, new, time in
      let sid = try await old.sessions.createSession(group: .shared, title: "t", kind: .agent, createdBy: "morgan", model: .test)
      let script = InferenceScript([
        Fix.failing(.rateLimited(retryAt: anchor.addingTimeInterval(600))),
        Fix.replying("done"),
      ])
      let config = makeConfig(inference: { try await script($0) })
      let first = SessionExecution(space: old, loopConfig: config)
      let second = SessionExecution(space: new, loopConfig: config)

      first.start()
      try await first.enqueue(item: Fix.message("hello"), to: sid)
      try await until("attempt 1") { script.count == 1 }
      try await time.asleep("the retry delay", dueIn: 600)

      second.start()
      await first.shutdown()
      try await holds("the drained worker tried nothing more") { script.count == 1 }

      await time.advance(to: anchor.addingTimeInterval(100))
      try await holds("no attempt a hundred seconds in") { script.count == 1 }
      await time.advance(to: anchor.addingTimeInterval(600))
      try await until("attempt 2") { script.count == 2 }
      let offsets = script.attempts.value.map { $0.at.timeIntervalSince(anchor) }
      #expect(abs(offsets[1] - 600) < 0.001)
      try await settles(sid, in: new, time)
      await second.shutdown()
    }
  }

  @Test func `a turn waiting on its model moves to the worker that starts beside it`() async throws {
    try await rolling { old, new, time in
      let sid = try await old.sessions.createSession(group: .shared, title: "t", kind: .agent, createdBy: "morgan", model: .test)
      let script = InferenceScript([
        { _ in
          await Latch().wait(unless: { Task.isCancelled })
          throw CancellationError()
        },
        Fix.replying("done"),
      ])
      let config = makeConfig(inference: { try await script($0) })
      let first = SessionExecution(space: old, loopConfig: config)
      let second = SessionExecution(space: new, loopConfig: config)

      first.start()
      try await first.enqueue(item: Fix.message("hello"), to: sid)
      try await until("the first worker's request") { script.count == 1 }

      second.start()
      for _ in 0 ..< 5 { await time.advance(by: 1) }
      try await holds("the turn stays with the worker that holds it") { script.count == 1 }

      await first.shutdown()
      try await settles(sid, in: new, time)
      #expect(script.count == 2)
      await second.shutdown()
    }
  }

  @Test(arguments: [false, true])
  func `a turn resumes from the inference params persisted by dev 38`(held: Bool) async throws {
    try await withKernelDeps { time in
      let folder = try ScratchFolder("rollover-pre040")
      let file = folder.url.appending(path: "space.sqlite")
      let old = try Space.open(file: file)
      let sid = try await old.sessions.createSession(group: .shared, title: "t", kind: .agent, createdBy: "morgan", model: .test)
      let script = InferenceScript([
        { _ in
          await Latch().wait(unless: { Task.isCancelled })
          throw CancellationError()
        },
        Fix.replying("done"),
      ])
      let config = makeConfig(inference: { try await script($0) })
      let first = SessionExecution(space: old, loopConfig: config)
      first.start()
      try await first.enqueue(item: Fix.message("hello"), to: sid)
      try await until("the old worker's inference starts") { script.count == 1 }
      await first.shutdown()

      let address = try await old.writer.write { db in
        let stored = try String.fetchOne(db, sql: "SELECT address FROM wuwei_job WHERE address LIKE ? AND phase = 'live'", arguments: ["InferenceJob/\(sid.rawValue):%"])
        let address = try #require(stored)
        try db.execute(sql: "UPDATE wuwei_job SET params = CAST(json_remove(CAST(params AS TEXT), '$.ping') AS BLOB) WHERE address = ?", arguments: [address])
        if held { try db.execute(sql: "UPDATE sessions SET hold = 'interrupted' WHERE id = ?", arguments: [sid.rawValue]) }
        try db.execute(sql: """
        ALTER TABLE wuwei_job DROP COLUMN creator;
        ALTER TABLE wuwei_mail DROP COLUMN lifecycle;
        DELETE FROM grdb_migrations WHERE identifier = '040';
        """)
        #expect(try db.columns(in: "wuwei_job").allSatisfy { $0.name != "creator" })
        #expect(try String.fetchOne(db, sql: "SELECT identifier FROM grdb_migrations ORDER BY identifier DESC LIMIT 1") == "044")
        return address
      }
      try await old.close()
      let new = try Space.open(file: file)
      #expect(try await new.writer.read { db in
        try String.fetchOne(db, sql: "SELECT creator FROM wuwei_job WHERE address = ?", arguments: [address]) == SessionCell.ID(sid.rawValue).description
      })
      let second = SessionExecution(space: new, loopConfig: config)
      second.start()
      await time.advance(by: 12)
      try await until("the new worker tries to host the persisted inference") {
        try await new.writer.read { db in
          try Int.fetchOne(db, sql: "SELECT fence FROM wuwei_addressable WHERE address = ?", arguments: [address])! > 1
        }
      }
      if held {
        try await until("the held turn's lost job ends and its mail is consumed") {
          try await new.writer.read { db in
            try String.fetchOne(db, sql: "SELECT phase FROM wuwei_job WHERE address = ?", arguments: [address]) == "done"
              && Int.fetchOne(db, sql: "SELECT count(*) FROM wuwei_mail WHERE recipient = ? AND lifecycle = 'lost'", arguments: [SessionCell.ID(sid.rawValue).description]) == 0
          }
        }
        #expect(try await new.sessions.record(sid).hold == .interrupted)
        #expect(script.count == 1)
        try await second.resume(sid)
      }
      try await until("the persisted turn settles", timeout: .seconds(1)) {
        try await new.sessions.settledWork(sid)
      }
      #expect(script.count == 2)
      #expect(try await new.sessions.lines(sid).assistantLines.map(\.text) == ["done"])
      #expect(try await new.writer.read { db in
        try Int.fetchOne(db, sql: "SELECT step_try FROM session_runtime WHERE session_id = ?", arguments: [sid.rawValue]) == 1
      })
      #expect(try await new.writer.read { db in
        try String.fetchOne(db, sql: "SELECT phase FROM wuwei_job WHERE address = ?", arguments: [address]) == "done"
      })
      await second.shutdown()
      try await new.close()
    }
  }

  @Test(arguments: [false, true])
  func `stale and unrelated lost jobs do not interrupt the current inference`(stale: Bool) async throws {
    try await rolling { space, _, _ in
      let sid = try await space.sessions.createSession(group: .shared, title: "t", kind: .agent, createdBy: "morgan", model: .test)
      let script = InferenceScript([
        { _ in
          await Latch().wait(unless: { Task.isCancelled })
          throw CancellationError()
        },
      ])
      let execution = SessionExecution(space: space, loopConfig: makeConfig(inference: { try await script($0) }))
      execution.start()
      try await execution.enqueue(item: Fix.message("hello"), to: sid)
      try await until("the current inference starts") { script.count == 1 }
      let job = stale ? "InferenceJob/\(sid.rawValue):0:0:99" : "ToolCallJob/\(sid.rawValue):0:0"
      try await space.worker.call(SessionCell.ID(sid.rawValue)) { try $0.lost(job) }
      #expect(try await space.writer.read { db in
        try Int.fetchOne(db, sql: "SELECT step_try FROM session_runtime WHERE session_id = ?", arguments: [sid.rawValue]) == 0
      })
      #expect(try await space.sessions.record(sid).hold == .normal)
      #expect(script.count == 1)
      await execution.shutdown()
    }
  }

  @Test func `a tool call cancelled at the quiesce answers the restart failure and the turn goes on`() async throws {
    try await rolling { old, new, time in
      let sid = try await old.sessions.createSession(group: .shared, title: "t", kind: .agent, createdBy: "morgan", model: .test)
      let script = InferenceScript([
        Fix.replying("looking", calls: [.init(id: "call_0", name: "test_tool", arguments: .object([:]))]),
        Fix.replying("done"),
      ])
      let exec = ExecScript { _ in
        await Latch().wait(unless: { Task.isCancelled })
        try Task.checkCancellation()
        return .exec(.init(output: "ok", exitCode: 0))
      }
      let config = makeConfig(executeTool: { try await exec($0) }, inference: { try await script($0) })
      let first = SessionExecution(space: old, loopConfig: config)
      let second = SessionExecution(space: new, loopConfig: config)

      first.start()
      try await first.enqueue(item: Fix.message("hello"), to: sid)
      try await until("the call runs") { exec.calls.value.count == 1 }

      second.start()
      for _ in 0 ..< 5 { await time.advance(by: 1) }
      try await holds("the call stays with the worker that runs it") { exec.calls.value.count == 1 && script.count == 1 }

      await first.shutdown()
      try await settles(sid, in: new, time)
      #expect(exec.calls.value.count == 1)
      #expect(script.count == 2)
      let results = try await toolResults(sid, in: new)
      #expect(results.map(\.text) == [serverRestartedToolMessage])
      #expect(results.allSatisfy { $0.message.toolResult?.isError == true })
      await second.shutdown()
    }
  }

  @Test func `a tool call that finishes at the quiesce answers its own result`() async throws {
    try await rolling { old, new, time in
      let sid = try await old.sessions.createSession(group: .shared, title: "t", kind: .agent, createdBy: "morgan", model: .test)
      let script = InferenceScript([
        Fix.replying("looking", calls: [.init(id: "call_0", name: "test_tool", arguments: .object([:]))]),
        Fix.replying("done"),
      ])
      let held = Held()
      let cancelled = Box(false)
      let exec = ExecScript { _ in
        await withTaskCancellationHandler {
          await held.wait()
        } onCancel: {
          cancelled.withLock { $0 = true }
        }
        return .exec(.init(output: "ok", exitCode: 0))
      }
      let config = makeConfig(executeTool: { try await exec($0) }, inference: { try await script($0) })
      let first = SessionExecution(space: old, loopConfig: config)
      let second = SessionExecution(space: new, loopConfig: config)

      first.start()
      try await first.enqueue(item: Fix.message("hello"), to: sid)
      try await until("the call runs") { exec.calls.value.count == 1 }

      second.start()
      for _ in 0 ..< 5 { await time.advance(by: 1) }
      try await holds("the call stays with the worker that runs it") { exec.calls.value.count == 1 && script.count == 1 }

      let drain = Task { await first.shutdown() }
      try await until("the drain cancels the call") { cancelled.value }
      held.release()
      await drain.value
      try await settles(sid, in: new, time)
      #expect(exec.calls.value.count == 1)
      #expect(script.count == 2)
      let results = try await toolResults(sid, in: new)
      #expect(results.map(\.text) == ["ok"])
      #expect(results.allSatisfy { $0.message.toolResult?.isError == false })
      await second.shutdown()
    }
  }

  @Test func `a call a crashed process left started answers the restart failure once the lease moves`() async throws {
    try await withKernelDeps { time in
      let folder = try ScratchFolder("crash")
      let file = folder.url.appending(path: "space.sqlite")
      let crashed = try ScratchFolder("crashed")
      let copy = crashed.url.appending(path: "space.sqlite")
      let old = try Space.open(file: file)
      let sid = try await old.sessions.createSession(group: .shared, title: "t", kind: .agent, createdBy: "morgan", model: .test)
      let held = Held()
      let exec = ExecScript { _ in
        await held.wait()
        return .exec(.init(output: "ok", exitCode: 0))
      }
      let script = InferenceScript([
        Fix.replying("looking", calls: [.init(id: "call_0", name: "test_tool", arguments: .object([:]))]),
        Fix.replying("done"),
      ])
      let config = makeConfig(executeTool: { try await exec($0) }, inference: { try await script($0) })
      let first = SessionExecution(space: old, loopConfig: config)
      first.start()
      try await first.enqueue(item: Fix.message("hello"), to: sid)
      try await until("the call runs") { exec.calls.value.count == 1 }

      // What a process killed mid-call leaves: the call started, unanswered, its tool still held.
      do {
        let source = try DatabaseQueue(path: file.path)
        try source.backup(to: DatabaseQueue(path: copy.path))
      }

      let new = try Space.open(file: copy)
      let second = SessionExecution(space: new, loopConfig: config)
      second.start()
      try await settles(sid, in: new, time)
      #expect(exec.calls.value.count == 1)
      #expect(script.count == 2)
      let results = try await toolResults(sid, in: new)
      #expect(results.map(\.text) == [serverRestartedToolMessage])
      #expect(results.allSatisfy { $0.message.toolResult?.isError == true })

      held.release()
      await first.shutdown()
      await second.shutdown()
      try await old.close()
      try await new.close()
    }
  }

  @Test func `mail sent through the new worker reaches a turn the old one still holds`() async throws {
    try await rolling { old, new, time in
      let sid = try await old.sessions.createSession(group: .shared, title: "t", kind: .agent, createdBy: "morgan", model: .test)
      let script = InferenceScript([
        Fix.replying("looking", calls: [.init(id: "call_0", name: "test_tool", arguments: .object([:]))]),
        Fix.replying("done"),
        Fix.replying("and that"),
      ])
      let gate = Latch()
      let exec = ExecScript { _ in
        await gate.wait(unless: { Task.isCancelled })
        try Task.checkCancellation()
        return .exec(.init(output: "ok", exitCode: 0))
      }
      let config = makeConfig(executeTool: { try await exec($0) }, inference: { try await script($0) })
      let first = SessionExecution(space: old, loopConfig: config)
      let second = SessionExecution(space: new, loopConfig: config)

      first.start()
      try await first.enqueue(item: Fix.message("hello"), to: sid)
      try await until("the call runs") { exec.calls.value.count == 1 }

      second.start()
      let more = Fix.message("more", message: "m2")
      try await second.enqueue(item: more, to: sid)
      for _ in 0 ..< 3 { await time.advance(by: 1) }
      try await until("the new worker's mail reaches the held turn") {
        try await old.sessions.undrainedInputs(sid).contains { $0.input == more }
      }
      #expect(exec.calls.value.count == 1)
      #expect(try await old.worker.call(SessionCell.ID(sid.rawValue)) { _ in true })
      gate.release()
      try await settlesAcrossWorkers(sid, old, time)
      #expect(exec.calls.value.count == 1)
      #expect(script.count <= 3)
      #expect(try await toolResults(sid, in: old).map(\.text) == ["ok"])
      await first.shutdown()
      await second.shutdown()
    }
  }

  /// `until` plus the one move this turn can need: a job that answers on the other worker posts its
  /// mail to the session cell, and `Worker.poke` is lossy across workers, so only the receiving
  /// worker's next 1 s scan delivers it — which only a clock advance runs. Advance one second at a
  /// time, only while such mail is queued, a scan is armed and the wait has stalled, and at most
  /// `scans` times: a settle the pokes carry is never hurried, and the clock stays inside the
  /// workers' 10 s leases.
  private func settlesAcrossWorkers(_ sid: SessionID, _ old: Space, _ time: TimeControl, scans: Int = 6) async throws {
    let clock = ContinuousClock()
    var advanced = 0
    var last = clock.now
    try await until("the held turn settles") {
      if try await old.sessions.settledWork(sid) { return true }
      if advanced < scans, time.sleeping(dueIn: 1) > 0, clock.now - last > .milliseconds(100),
         try await pendingSessionMail(sid, old)
      {
        await time.advance(by: 1)
        advanced += 1
        last = clock.now
      }
      return false
    }
  }

  private func pendingSessionMail(_ sid: SessionID, _ space: Space) async throws -> Bool {
    try await space.writer.read { db in
      try Bool.fetchOne(db, sql: "SELECT EXISTS (SELECT 1 FROM wuwei_mail WHERE recipient = ?)", arguments: ["\(SessionMail.kind)/\(sid.rawValue)"]) ?? false
    }
  }

  @Test func `an interrupt through the new worker stops the old worker's call without running it again`() async throws {
    try await rolling { old, new, time in
      let sid = try await old.sessions.createSession(group: .shared, title: "t", kind: .agent, createdBy: "morgan", model: .test)
      let script = InferenceScript([
        Fix.replying("looking", calls: [.init(id: "call_0", name: "test_tool", arguments: .object([:]))]),
      ])
      let stopped = Box(0)
      let exec = ExecScript { _ in
        await Latch().wait(unless: { Task.isCancelled })
        stopped.withLock { $0 += 1 }
        throw CancellationError()
      }
      let config = makeConfig(executeTool: { try await exec($0) }, inference: { try await script($0) })
      let first = SessionExecution(space: old, loopConfig: config)
      let second = SessionExecution(space: new, loopConfig: config)

      first.start()
      try await first.enqueue(item: Fix.message("hello"), to: sid)
      try await until("the call runs") { exec.calls.value.count == 1 }

      second.start()
      try await second.interrupt(sid)
      // One scan carries the interrupt to the worker that holds the call; the rest of the chain is pokes.
      await time.advance(by: 2)
      try await until("the call is stopped") { stopped.value == 1 }
      for _ in 0 ..< 3 { await time.advance(by: 1) }
      try await holds("the call ran once") { exec.calls.value.count == 1 && script.count == 1 }
      await first.shutdown()
      await second.shutdown()
    }
  }

  @Test func `a compaction in flight at the roll is made by the worker that takes over`() async throws {
    try await rolling { old, new, time in
      let sid = try await old.sessions.createSession(group: .shared, title: "t", kind: .agent, createdBy: "morgan", model: .test)
      let script = InferenceScript([
        Fix.replying("folding", calls: [.init(id: "call_c", name: "compact", arguments: .object(["summary": .string("what happened")]))]),
        Fix.replying("on with it"),
      ])
      let asked = Box(0)
      var config = makeConfig(inference: { try await script($0) })
      config.runningWork = { _ in
        let first = asked.withLock { asked in
          asked += 1
          return asked == 1
        }
        if first {
          await Latch().wait(unless: { Task.isCancelled })
          throw CancellationError()
        }
        return []
      }
      let first = SessionExecution(space: old, loopConfig: config)
      let second = SessionExecution(space: new, loopConfig: config)

      first.start()
      try await first.enqueue(item: Fix.message("hello"), to: sid)
      try await until("the compaction gathers what runs") { asked.value == 1 }

      second.start()
      for _ in 0 ..< 5 { await time.advance(by: 1) }
      try await holds("the compaction stays with the worker that holds it") { asked.value == 1 }

      await first.shutdown()
      try await settles(sid, in: new, time)
      #expect(try await new.sessions.generationState(sid).generation == 1)
      #expect(script.count == 2)
      await second.shutdown()
    }
  }

  @Test func `a warming ping in flight at the roll is spent once and made by the worker that takes over`() async throws {
    try await rolling { old, new, time in
      let sid = try await old.sessions.createSession(group: .shared, title: "warm", kind: .agent, createdBy: "morgan", model: .test)
      let schedule = WarmingSchedule(intervalSeconds: 10, lifetimeSeconds: 1000, maxPings: 1)
      let gate = Latch()
      let script = InferenceScript([
        Fix.replying("hi", warming: schedule),
        { _ in
          await gate.wait(unless: { Task.isCancelled })
          try Task.checkCancellation()
          return Fix.reply("still here", warming: schedule)
        },
        Fix.replying("still here", warming: schedule),
      ])
      let config = makeConfig(inference: { try await script($0) })
      let first = SessionExecution(space: old, loopConfig: config)
      let second = SessionExecution(space: new, loopConfig: config)

      first.start()
      try await first.enqueue(item: Fix.message("hello"), to: sid)
      try await until("the reply") { script.count == 1 }
      try await until("warming is armed") { old.worker.cell(SessionCell.ID(sid.rawValue)).turn()?.warming != nil }

      // The wake comes due while the old worker still holds the session: it starts the ping there, and the ping is still going when the worker drains.
      try await time.asleep("the warming wake", dueIn: 10)
      await time.advance(by: 10)
      try await until("the ping starts on the old worker") { script.count == 2 }

      second.start()
      await first.shutdown()
      try await until("the ping is answered on the worker that takes over") {
        await time.advance(by: 1)
        return script.count == 3
      }
      try await until("its reply lands") { try await new.sessions.lines(sid).assistantLines.count == 2 }
      #expect(script.attempts.value[1].ping)
      #expect(script.attempts.value[2].ping)
      #expect(try await new.sessions.transcriptLines(sid).count(where: { $0.key == LineKey.cacheWarming }) == 1)
      try await holds("one ping job") { script.count == 3 }
      await second.shutdown()
    }
  }

  @Test func `a legacy conversion held at the roll opens one line generation`() async throws {
    try await rolling { old, new, time in
      let sid = try await old.sessions.createSession(group: .shared, title: "legacy roll", kind: .agent, createdBy: "morgan", model: .test)
      try await seedLegacyGeneration(old, sid)
      let asked = Box(0)
      let script = InferenceScript([Fix.replying("continued")])
      var config = makeConfig(inference: { request in
        #expect(request.generation == 1)
        #expect(request.lines.contains { $0.key == "head:summary" && $0.text.contains("session_legacy_items") })
        return try await script(request)
      })
      config.runningWork = { _ in
        let first = asked.withLock { count in count += 1; return count == 1 }
        if first {
          await Latch().wait(unless: { Task.isCancelled })
          throw CancellationError()
        }
        return []
      }
      let first = SessionExecution(space: old, loopConfig: config)
      let second = SessionExecution(space: new, loopConfig: config)
      first.start()
      try await first.enqueue(item: Fix.message("continue"), to: sid)
      try await until("the legacy conversion gathers its head") { asked.value == 1 }
      second.start()
      for _ in 0 ..< 5 { await time.advance(by: 1) }
      try await holds("the conversion stays with its worker") { asked.value == 1 && script.count == 0 }
      await first.shutdown()
      try await settles(sid, in: new, time)
      #expect(try await new.sessions.generation(sid) == 1)
      #expect(script.count == 1)
      #expect(try await new.sessions.transcriptLines(sid, generation: 0).isEmpty)
      await second.shutdown()
    }
  }
}

/// A wait that cancellation does not end: the test opens it.
private final class Held: Sendable {
  private let waiting = Mutex<[CheckedContinuation<Void, Never>]?>([])

  func wait() async {
    await withCheckedContinuation { continuation in
      let open = waiting.withLock { waiting -> Bool in
        guard waiting != nil else { return true }
        waiting?.append(continuation)
        return false
      }
      if open { continuation.resume() }
    }
  }

  func release() {
    let held = waiting.withLock { waiting -> [CheckedContinuation<Void, Never>] in
      let held = waiting ?? []
      waiting = nil
      return held
    }
    for continuation in held { continuation.resume() }
  }
}
