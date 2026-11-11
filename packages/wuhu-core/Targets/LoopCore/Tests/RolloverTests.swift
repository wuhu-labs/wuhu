import ControlledTime
import Dependencies
import Foundation
import JSONValue
@testable import LoopCore
import Scratch
import SessionDomain
import SpaceCore
import Testing
import WuhuAI

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

  private func settles(_ session: SessionID, in space: Space, _ time: TimeControl) async throws {
    try await until("the session settles on the worker that took over") {
      await time.advance(by: 1)
      return try await space.sessions.settledWork(session)
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

  @Test func `a tool call in flight at the roll runs once and the turn goes on`() async throws {
    try await rolling { old, new, time in
      let sid = try await old.sessions.createSession(group: .shared, title: "t", kind: .agent, createdBy: "morgan", model: .test)
      let script = InferenceScript([
        Fix.replying("looking", calls: [.init(id: "call_0", name: "exec", arguments: .object([:]))]),
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
      await second.shutdown()
    }
  }

  @Test func `mail sent through the new worker reaches a turn the old one still holds`() async throws {
    try await rolling { old, new, time in
      let sid = try await old.sessions.createSession(group: .shared, title: "t", kind: .agent, createdBy: "morgan", model: .test)
      let script = InferenceScript([
        Fix.replying("looking", calls: [.init(id: "call_0", name: "exec", arguments: .object([:]))]),
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
      try await second.enqueue(item: Fix.message("more", message: "m2"), to: sid)
      for _ in 0 ..< 3 { await time.advance(by: 1) }
      try await holds("the call stays with the worker that runs it") { exec.calls.value.count == 1 }
      gate.release()
      try await settles(sid, in: new, time)
      #expect(exec.calls.value.count == 1)
      #expect(script.count <= 3)
      await first.shutdown()
      await second.shutdown()
    }
  }

  @Test func `an interrupt through the new worker stops the old worker's call without running it again`() async throws {
    try await rolling { old, new, time in
      let sid = try await old.sessions.createSession(group: .shared, title: "t", kind: .agent, createdBy: "morgan", model: .test)
      let script = InferenceScript([
        Fix.replying("looking", calls: [.init(id: "call_0", name: "exec", arguments: .object([:]))]),
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
      try await until("the call is stopped") {
        await time.advance(by: 1)
        return stopped.value == 1
      }
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
}
