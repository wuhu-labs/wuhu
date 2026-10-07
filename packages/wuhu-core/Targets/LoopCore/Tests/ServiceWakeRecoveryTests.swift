#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import Clocks
import Dependencies
import GRDB
@testable import LoopCore
import SessionDomain
@testable import SpaceCore
import Testing
import WuhuAI

@Suite(.timeLimit(.minutes(1))) struct ServiceWakeRecoveryTests {
  @Test(arguments: [false, true])
  func corruptIdleTaskEligibilityDoesNotSuppressHealthyBoot(hasParent: Bool) async throws {
    try await withKernelDeps { _ in
      let space = try Space.inMemory()
      let sessions = space.sessions
      let healthy = try await sessions.createSession(group: .shared, title: "healthy", kind: .agent, createdBy: "morgan", model: .test)
      let bad = try await sessions.createSession(group: .shared, title: "idle task", kind: .task, parent: hasParent ? healthy : nil, createdBy: "morgan", executor: .kernel(.test))
      _ = try await sessions.enqueue(healthy, input: Fix.message("boot work"))
      _ = try await sessions.enqueue(bad, input: Fix.message("old", message: "old"))
      _ = try await sessions.drainQueue(bad)
      try await space.writer.write { db in
        try db.execute(sql: "UPDATE sessions SET work = 'no_work' WHERE id = ?", arguments: [bad.rawValue])
        try db.execute(sql: "UPDATE session_queue SET payload = '{}' WHERE session_id = ?", arguments: [bad.rawValue])
      }
      let failures = Box<[SessionID]>([])
      #expect(try await sessions.bootSessions { id, _ in failures.withLock { $0.append(id) } } == [healthy])
      #expect(failures.value == [bad])
      let logs = RecordedLogs()
      let calls = Box<[SessionID]>([])
      let commits = AsyncStream<SessionID>.makeStream()
      defer { commits.continuation.finish() }
      let service = await SessionService(sessions: sessions, loopConfig: makeConfig(inference: { request in
        calls.withLock { $0.append(request.sessionID) }
        var reply = Fix.reply("done")
        reply.committed = { _, _ in commits.continuation.yield(request.sessionID) }
        return reply
      }), log: logs.logger) { SessionRepo(sessions: sessions, id: $0) }
      try await runService(service) { service in
        var iterator = commits.stream.makeAsyncIterator()
        #expect(await iterator.next() == healthy)
        let record = try await sessions.record(bad)
        #expect(record.work == .errored)
        #expect(record.errorMessage?.contains("boot eligibility failed:") == true)
        #expect(logs.all.contains { $0.level == .error && $0.message == "boot eligibility failed" && $0.metadata["session"] == bad.rawValue && $0.metadata["error"]?.isEmpty == false })
        #expect(await service.registry.existing(bad) == nil)
        #expect(calls.value == [healthy])
        #expect(try await sessions.notifications(recipient: "owner").contains { $0.kind == .sessionErrored && $0.source == bad.rawValue })
        let payload = try await space.writer.read { db in
          try String.fetchOne(db, sql: "SELECT payload FROM session_queue WHERE session_id = ?", arguments: [bad.rawValue])
        }
        #expect(payload == "{}")
        _ = try await service.restart(bad, executor: nil, note: nil)
        let hydration = try await sessions.hydrate(bad)
        #expect(hydration.record.work == .noWork)
        #expect(hydration.transcript.kernel.environment.settle == SettleState())
        #expect(try await sessions.settleState(bad) == SettleState())
        _ = try await service.enqueue(item: Fix.message("recovered", message: "recovered"), to: bad)
        #expect(await iterator.next() == bad)
        #expect(try await sessions.bootSessions().isEmpty)
        let compacted = try await sessions.writeCompaction(
          bad, head: .init(id: UUID(), timestamp: anchor, summary: "recovered", snapshot: .init(), settle: .init()), kept: nil,
        )
        #expect(compacted.environment.settle == SettleState())
        #expect(try await sessions.settleState(bad) == SettleState())
        #expect(try await sessions.bootSessions() == [bad])
        let preserved = try await space.writer.read { db in
          try String.fetchOne(db, sql: "SELECT payload FROM session_queue WHERE session_id = ? AND id = 1", arguments: [bad.rawValue])
        }
        #expect(preserved == payload)
        let fresh = try await sessions.createSession(group: .shared, title: "fresh", kind: .agent, createdBy: "morgan", model: .test)
        _ = try await service.enqueue(item: Fix.message("fresh", message: "fresh"), to: fresh)
        #expect(await iterator.next() == fresh)
      }
    }
  }

  @Test(arguments: [false, true])
  func corruptTranscriptCanStartOverWithoutOverwritingPayload(boot: Bool) async throws {
    try await withKernelDeps { _ in
      let space = try Space.inMemory()
      let sessions = space.sessions
      let bad = try await sessions.createSession(group: .shared, title: "bad", kind: .agent, createdBy: "morgan", model: .test)
      let healthy = try await sessions.createSession(group: .shared, title: "healthy", kind: .agent, createdBy: "morgan", model: .test)
      try await sessions.appendAssistant(bad, attemptID: UUID(), message: Fix.reply("old").message, metadata: Fix.reply("old").metadata)
      try await space.writer.write { db in
        try db.execute(sql: "UPDATE session_contents SET payload = '{}' WHERE session_id = ?", arguments: [bad.rawValue])
      }
      _ = try await sessions.enqueue(healthy, input: Fix.message("healthy boot", message: "healthy-boot"))
      if boot { _ = try await sessions.enqueue(bad, input: Fix.message("bad boot", message: "bad-boot")) }
      #expect(try await sessions.bootSessions() == (boot ? [bad, healthy] : [healthy]))
      let errors = ErrorCommits(bad)
      sessions.writer.add(transactionObserver: errors)
      defer { errors.stream.continuation.finish() }
      let logs = RecordedLogs()
      let calls = Box<[SessionID]>([])
      let commits = AsyncStream<SessionID>.makeStream()
      defer { commits.continuation.finish() }
      let service = await SessionService(sessions: sessions, loopConfig: makeConfig(inference: { request in
        calls.withLock { $0.append(request.sessionID) }
        var reply = Fix.reply("done")
        reply.committed = { _, _ in commits.continuation.yield(request.sessionID) }
        return reply
      }), log: logs.logger) { SessionRepo(sessions: sessions, id: $0) }
      try await runService(service) { service in
        var iterator = commits.stream.makeAsyncIterator()
        #expect(await iterator.next() == healthy)
        if !boot { _ = try await sessions.enqueue(bad, input: Fix.message("new delivery", message: "bad-signal")) }
        for await _ in errors.stream.stream { break }
        let record = try await sessions.record(bad)
        #expect(record.work == .errored)
        #expect(record.errorMessage != nil)
        let phase = boot ? "boot wake" : "work signal wake"
        #expect(logs.all.contains { $0.level == .error && $0.message == "\(phase) failed" && $0.metadata["session"] == bad.rawValue })
        #expect(await service.registry.existing(bad) == nil)
        #expect(!calls.value.contains(bad))
        await #expect(throws: SessionError.unreadableData(bad)) { try await service.resume(bad) }
        #expect(try await sessions.record(bad).work == .errored)
        _ = try await service.restart(bad, executor: nil, note: nil)
        _ = try await service.enqueue(item: Fix.message("fresh", message: "bad-fresh"), to: bad)
        #expect(await iterator.next() == bad)
        let payload = try await space.writer.read { db in
          try String.fetchOne(db, sql: "SELECT payload FROM session_contents WHERE session_id = ? AND payload = '{}' LIMIT 1", arguments: [bad.rawValue])
        }
        #expect(payload == "{}")
        #expect(try await sessions.record(bad).errorMessage == nil)
        _ = try await service.enqueue(item: Fix.message("still healthy", message: "healthy-again"), to: healthy)
        #expect(await iterator.next() == healthy)
      }
    }
  }

  @Test func fatalLoopFailureWithCorruptParentedHistoryPersistsError() async throws {
    try await withKernelDeps { _ in
      let space = try Space.inMemory()
      let sessions = space.sessions
      let parent = try await sessions.createSession(group: .shared, title: "parent", kind: .agent, createdBy: "morgan", model: .test)
      let task = try await sessions.createSession(group: .shared, title: "task", kind: .task, parent: parent, createdBy: "morgan", executor: .kernel(.test))
      let errors = ErrorCommits(task)
      sessions.writer.add(transactionObserver: errors)
      defer { errors.stream.continuation.finish() }
      let service = await SessionService(sessions: sessions, loopConfig: makeConfig(inference: { request in
        #expect(request.sessionID == task)
        try await space.writer.write { db in
          try db.execute(sql: "UPDATE session_queue SET payload = '{}' WHERE session_id = ?", arguments: [task.rawValue])
        }
        throw InferenceError.invalidInput(status: 400, body: "terminal")
      }))
      try await runService(service) { service in
        _ = try await service.enqueue(item: Fix.message("task input"), to: task)
        for await _ in errors.stream.stream { break }
        let record = try await sessions.record(task)
        #expect(record.work == .errored)
        #expect(record.errorMessage?.contains("terminal") == true)
        #expect(try await sessions.notifications(recipient: "owner").contains { $0.kind == .sessionErrored && $0.source == task.rawValue })
        let actor = try #require(await service.registry.existing(task))
        #expect(await actor.live.sessionStatus.stopped)
      }
    }
  }

  @Test(arguments: [false, true])
  func permanentDateOrExecutorWakeErrorIsNotReposted(executor: Bool) async throws {
    try await withKernelDeps { _ in
      let space = try Space.inMemory()
      let sessions = space.sessions
      let parent = try await sessions.createSession(group: .shared, title: "parent", kind: .agent, createdBy: "morgan", model: .test)
      let bad = try await sessions.createSession(group: .shared, title: "bad", kind: .agent, parent: parent, createdBy: "morgan", executor: .kernel(.test), snapshot: .init())
      let healthy = try await sessions.createSession(group: .shared, title: "healthy", kind: .agent, createdBy: "morgan", model: .test)
      _ = try await sessions.enqueue(healthy, input: Fix.message("boot"))
      let commits = AsyncStream<SessionID>.makeStream()
      let errors = ErrorCommits(bad)
      sessions.writer.add(transactionObserver: errors)
      defer { commits.continuation.finish(); errors.stream.continuation.finish() }
      let logs = RecordedLogs()
      let hydrations = Box(0)
      let service = await SessionService(sessions: sessions, loopConfig: makeConfig(inference: { request in
        #expect(request.sessionID != bad)
        var reply = Fix.reply("done")
        reply.committed = { _, _ in commits.continuation.yield(request.sessionID) }
        return reply
      }), log: logs.logger) { id in
        SessionRepo(sessions: sessions, id: id, hydrationRead: { store, session in
          if session == bad { hydrations.withLock { $0 += 1 } }
          return try await store.hydrate(session)
        })
      }
      try await runService(service) { service in
        var iterator = commits.stream.makeAsyncIterator()
        #expect(await iterator.next() == healthy)
        try await space.writer.write { db in
          if executor {
            try db.execute(sql: "UPDATE sessions SET executor_config = '{}' WHERE id = ?", arguments: [bad.rawValue])
          } else {
            try db.execute(sql: "INSERT INTO session_queue (session_id, id, input_id, payload, enqueued_at, drained_at) VALUES (?, 1, 'bad-date', '{}', ?, 'oops')", arguments: [bad.rawValue, SQLiteDateFormat.string(from: anchor)])
          }
        }
        // Posting directly isolates the unreadable record from enqueue's own validation.
        sessions.signals.post(bad)
        for await _ in errors.stream.stream { break }
        let work = try await space.writer.read { db in
          try String.fetchOne(db, sql: "SELECT work FROM sessions WHERE id = ?", arguments: [bad.rawValue])
        }
        #expect(work == "errored")
        #expect(hydrations.value == (executor ? 0 : 1))
        #expect(logs.all.filter { $0.message == "work signal wake failed" }.count == 1)
        #expect(!logs.all.contains { $0.message == "session wake retry scheduled" })
        #expect(await service.registry.existing(bad) == nil)
        #expect(try await sessions.notifications(recipient: "owner").contains { $0.kind == .sessionErrored && $0.source == bad.rawValue })
        await #expect(throws: SessionError.unreadableData(bad)) { try await service.resume(bad) }
        if !executor {
          _ = try await service.restart(bad, executor: nil, note: nil)
          #expect(try await sessions.settleState(bad) == SettleState())
          let old = try await space.writer.read { db in
            try String.fetchOne(db, sql: "SELECT drained_at FROM session_queue WHERE session_id = ? AND id = 1", arguments: [bad.rawValue])
          }
          #expect(old == "oops")
        }
        _ = try await service.enqueue(item: Fix.message("still healthy", message: "after-error"), to: healthy)
        #expect(await iterator.next() == healthy)
        #expect(logs.all.filter { $0.message == "work signal wake failed" }.count == 1)
      }
    }
  }

  @Test func cancellationJoinsPendingWakeBackoff() async throws {
    try await withKernelDeps { _ in
      let clock = WakeTestClock()
      try await withDependencies { $0.continuousClock = AnyClock(clock) } operation: {
        let sessions = try Space.inMemory().sessions
        let bad = try await sessions.createSession(group: .shared, title: "transient", kind: .agent, createdBy: "morgan", model: .test)
        let healthy = try await sessions.createSession(group: .shared, title: "healthy", kind: .agent, createdBy: "morgan", model: .test)
        _ = try await sessions.enqueue(healthy, input: Fix.message("boot"))
        let calls = Box(0)
        let commits = AsyncStream<Void>.makeStream()
        defer { commits.continuation.finish(); clock.sleeps.continuation.finish() }
        let service = await SessionService(sessions: sessions, loopConfig: makeConfig(inference: { _ in
          var reply = Fix.reply("done")
          reply.committed = { _, _ in commits.continuation.yield(()) }
          return reply
        })) { id in
          SessionRepo(sessions: sessions, id: id, hydrationRead: { store, session in
            if session == bad {
              calls.withLock { $0 += 1 }
              throw DatabaseError(resultCode: .SQLITE_LOCKED)
            }
            return try await store.hydrate(session)
          })
        }
        try await runService(service) { _ in
          for await _ in commits.stream { break }
          _ = try await sessions.enqueue(bad, input: Fix.message("wake"))
          for await _ in clock.sleeps.stream { break }
          #expect(calls.value == 1)
        }
        await clock.base.advance(by: .seconds(100))
        #expect(calls.value == 1)
        #expect(await service.registry.sessions.isEmpty)
        #expect(try await sessions.record(bad).work != .errored)
      }
    }
  }

  @Test(arguments: [false, true])
  func transientWakeRetriesAreBoundedAndDoNotBlockHealthySignals(exhausted: Bool) async throws {
    try await withKernelDeps { _ in
      let clock = WakeTestClock()
      try await withDependencies { $0.continuousClock = AnyClock(clock) } operation: {
        let space = try Space.inMemory()
        let sessions = space.sessions
        let bad = try await sessions.createSession(group: .shared, title: "transient", kind: .agent, createdBy: "morgan", model: .test)
        let healthy = try await sessions.createSession(group: .shared, title: "healthy", kind: .agent, createdBy: "morgan", model: .test)
        _ = try await sessions.enqueue(healthy, input: Fix.message("boot"))
        let calls = Box(0)
        let recovered = Box(false)
        let errors = ErrorCommits(bad)
        sessions.writer.add(transactionObserver: errors)
        let commits = AsyncStream<SessionID>.makeStream()
        defer { commits.continuation.finish(); errors.stream.continuation.finish(); clock.sleeps.continuation.finish() }
        let service = await SessionService(sessions: sessions, loopConfig: makeConfig(inference: { request in
          var reply = Fix.reply("done")
          reply.committed = { _, _ in commits.continuation.yield(request.sessionID) }
          return reply
        })) { id in
          SessionRepo(sessions: sessions, id: id, hydrationRead: { store, session in
            if session == bad {
              let count = calls.withLock { $0 += 1; return $0 }
              if !recovered.value && (exhausted || count <= 2) { throw DatabaseError(resultCode: .SQLITE_BUSY) }
            }
            return try await store.hydrate(session)
          })
        }
        try await runService(service) { service in
          var commits = commits.stream.makeAsyncIterator()
          var sleeps = clock.sleeps.stream.makeAsyncIterator()
          #expect(await commits.next() == healthy)
          _ = try await sessions.enqueue(bad, input: Fix.message("wake"))
          for attempt in 0 ..< (exhausted ? 3 : 2) {
            let deadline = try #require(await sleeps.next())
            let delay = Duration.seconds(1 << attempt)
            #expect(clock.now.duration(to: deadline) <= delay)
            #expect(clock.now.duration(to: deadline) >= delay - .microseconds(2))
            #expect(calls.value == attempt + 1)
            _ = try await sessions.enqueue(bad, input: Fix.message("during retry", message: "bad-\(attempt)"))
            _ = try await sessions.enqueue(healthy, input: Fix.message("independent", message: "healthy-\(attempt)"))
            #expect(await commits.next() == healthy)
            #expect(calls.value == attempt + 1)
            await clock.base.advance(by: delay / 2)
            #expect(calls.value == attempt + 1)
            await clock.base.advance(to: deadline.advanced(by: .microseconds(1)))
          }
          if exhausted {
            for await _ in errors.stream.stream { break }
            #expect(calls.value == 4)
            #expect(try await sessions.record(bad).work == .errored)
            #expect(await service.registry.existing(bad) == nil)
            // Ordinary Resume still works when the stored data itself is readable.
            recovered.withLock { $0 = true }
            try await service.resume(bad)
            #expect(await commits.next() == bad)
          } else {
            #expect(await commits.next() == bad)
            #expect(calls.value == 3)
            #expect(try await sessions.record(bad).work == .noWork)
          }
        }
      }
    }
  }
}

private final class ErrorCommits: TransactionObserver, Sendable {
  let session: String
  let stream = AsyncStream<Void>.makeStream()

  init(_ session: SessionID) { self.session = session.rawValue }

  func observes(eventsOfKind _: DatabaseEventKind) -> Bool { true }
  func databaseDidChange(with _: DatabaseEvent) {}
  func databaseDidRollback(_: Database) {}
  func databaseDidCommit(_ db: Database) {
    if (try? String.fetchOne(db, sql: "SELECT work FROM sessions WHERE id = ?", arguments: [session])) == "errored" {
      stream.continuation.yield(())
    }
  }
}

private struct WakeTestClock: Clock {
  let base = TestClock<Duration>()
  let sleeps = AsyncStream<TestClock<Duration>.Instant>.makeStream()
  var now: TestClock<Duration>.Instant { base.now }
  var minimumResolution: Duration { base.minimumResolution }

  func sleep(until deadline: TestClock<Duration>.Instant, tolerance: Duration?) async throws {
    if now.duration(to: deadline) <= .seconds(4) { sleeps.continuation.yield(deadline) }
    try await base.sleep(until: deadline, tolerance: tolerance)
  }
}
