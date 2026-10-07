#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import GRDB
@testable import LoopCore
import SessionDomain
@testable import SpaceCore
import Testing

@Suite(.timeLimit(.minutes(1))) struct ServiceBootIsolationTests {
  @Test(arguments: [false, true])
  func badBootSessionDoesNotCloseHealthySessionsOrAdmission(missing: Bool) async throws {
    try await withKernelDeps { _ in
      let space = try Space.inMemory()
      let sessions = space.sessions
      let first = try await sessions.createSession(group: .shared, title: "first", kind: .agent, createdBy: "morgan", model: .test)
      let bad = try await sessions.createSession(group: .shared, title: "bad", kind: .agent, createdBy: "morgan", model: .test)
      let last = try await sessions.createSession(group: .shared, title: "last", kind: .agent, createdBy: "morgan", model: .test)
      try await sessions.appendAssistant(bad, attemptID: UUID(), message: Fix.reply("old").message, metadata: Fix.reply("old").metadata)
      for (index, id) in [first, bad, last].enumerated() {
        _ = try await sessions.enqueue(id, input: Fix.message("input", message: "boot-\(index)"))
      }
      if !missing {
        try await space.writer.write { db in
          try db.execute(sql: "UPDATE session_contents SET payload = '{}' WHERE session_id = ?", arguments: [bad.rawValue])
        }
      }
      #expect(try await sessions.bootSessions() == [first, bad, last])
      let removed = Box(false)
      let calls = Box<[SessionID]>([])
      let commits = AsyncStream<SessionID>.makeStream()
      defer { commits.continuation.finish() }
      let logs = RecordedLogs()
      let service = await SessionService(sessions: sessions, loopConfig: makeConfig(inference: { request in
        calls.withLock { $0.append(request.sessionID) }
        var reply = Fix.reply("done")
        reply.committed = { _, _ in commits.continuation.yield(request.sessionID) }
        return reply
      }), log: logs.logger) { id in
        SessionRepo(sessions: sessions, id: id, queueHeadRead: { store, id in
          if missing, id == first, removed.withLock({ value in
            guard !value else { return false }
            value = true
            return true
          }) {
            try await space.writer.write { db in
              try db.execute(sql: "DELETE FROM sessions WHERE id = ?", arguments: [bad.rawValue])
            }
          }
          return try await store.queueHead(id)
        })
      }
      try await runService(service) { service in
        var iterator = commits.stream.makeAsyncIterator()
        let bootCommits = [await iterator.next(), await iterator.next()]
        #expect(Set(bootCommits.compactMap { $0 }) == Set([first, last]))
        #expect(!calls.value.contains(bad))
        #expect(logs.all.contains { $0.level == .error && $0.message == "boot wake failed" && $0.metadata["session"] == bad.rawValue && $0.metadata["error"]?.isEmpty == false })
        #expect(await service.registry.existing(bad) == nil)
        if missing {
          await #expect(throws: SessionStoreError.self) { try await sessions.record(bad) }
          #expect(logs.all.contains { $0.message == "could not mark session errored" && $0.metadata["session"] == bad.rawValue })
        } else {
          let record = try await sessions.record(bad)
          #expect(record.work == .errored)
          #expect(record.errorMessage?.contains("boot wake failed:") == true)
          let payload = try await space.writer.read { db in
            try String.fetchOne(db, sql: "SELECT payload FROM session_contents WHERE session_id = ?", arguments: [bad.rawValue])
          }
          #expect(payload == "{}")
          let notifications = try await sessions.notifications(recipient: "owner")
          let notice = try #require(notifications.first { $0.kind == .sessionErrored && $0.source == bad.rawValue })
          let errorNotice = try JSONDecoder().decode(Notifications.ErroredPayload.self, from: Data(notice.payload.utf8))
          #expect(errorNotice.message == nil)
          #expect(errorNotice.error == record.errorMessage)
          try await service.wake(bad)
          #expect(await service.registry.existing(bad) == nil)
        }
        try await service.wake(first)
        _ = try await service.enqueue(item: Fix.message("more", message: "healthy-more"), to: first)
        #expect(await iterator.next() == first)
        try await service.interrupt(first)
        try await service.resume(first)
        try await service.archive(first, force: true)
        try await service.unarchive(first)
        _ = try await service.restart(first, executor: nil, note: nil)
        _ = try await service.enqueue(item: Fix.message("after verbs", message: "healthy-verbs"), to: first)
        #expect(await iterator.next() == first)
        let fresh = try await sessions.createSession(group: .shared, title: "fresh", kind: .agent, createdBy: "morgan", model: .test)
        _ = try await service.enqueue(item: Fix.message("new session", message: "fresh"), to: fresh)
        #expect(await iterator.next() == fresh)
      }
      #expect(await service.registry.sessions.isEmpty)
    }
  }
}
