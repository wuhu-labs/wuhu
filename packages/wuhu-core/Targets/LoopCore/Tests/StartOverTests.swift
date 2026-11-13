import Dependencies
#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
@testable import LoopCore
import SessionDomain
@testable import SpaceCore
import StructuredQueries
import Testing

@Suite(.timeLimit(.minutes(1))) struct StartOverTests {
  @Test func corruptQueuedRowDoesNotReErrorAndReadableRowsReachOneFreshTurn() async throws {
    try await withKernelDeps { _ in
      let space = try Space.inMemory()
      let sessions = space.sessions
      let seen = Box<[[TranscriptLine]]>([])
      let committed = AsyncStream<Void>.makeStream()
      defer { committed.continuation.finish() }
      let config = makeConfig(inference: { request in
        seen.withLock { $0.append(request.lines) }
        var reply = Fix.reply("recovered")
        reply.committed = { _ in committed.continuation.yield(()) }
        return reply
      })
      let service = SessionExecution(space: space, loopConfig: config)
      let id = try await sessions.createSession(group: .shared, title: "queue recovery", kind: .agent, createdBy: "morgan", model: .test)
      try await sessions.put(id, input: Fix.message("first", message: "first"))
      try await sessions.put(id, input: Fix.message("bad", message: "bad"))
      try await sessions.put(id, input: Fix.message("last", message: "last"))
      try await space.worker.call(SessionCell.ID(id.rawValue)) {
        try $0.db.execute(SessionQueueRow.where { $0.sessionID.eq(id.rawValue) && $0.id.eq(Int64(2)) }.update { $0.payload = "{}" })
      }
      try await sessions.markErrored(id, message: "bad queue")
      try await until("the queue error is visible") { try await sessions.record(id).errorMessage == "bad queue" }
      try await runService(service) { service in
        _ = try await service.restart(id, executor: nil, note: "Started over.")
        for await _ in committed.stream { break }
        #expect(seen.value.count == 1)
        let lines = try #require(seen.value.first)
        let messages = lines.filter { $0.key.hasPrefix("message:") }
        #expect(messages.map(\.key) == ["message:first", "message:last"])
        #expect(messages.allSatisfy { $0.role == .user })
        try #require(messages.count == 2)
        #expect(messages[0].text.hasSuffix("\n\nfirst"))
        #expect(messages[1].text.hasSuffix("\n\nlast"))
        #expect(try await sessions.record(id).errorMessage == nil)
        #expect(try await sessions.generationState(id).note?.contains("Dropped 1 queued input(s)") == true)
        // The commit hook fires as the reply is written; wait for the turn to settle before archiving, whose busy check reads it.
        try await until("the turn settles") { try await sessions.settledWork(id) }
        try await service.archive(id)
      }
    }
  }

  @Test(arguments: [SessionKind.agent, .task])
  func queuedInputWakesTheNewGenerationAndItsFirstPromptCarriesState(kind: SessionKind) async throws {
    try await withKernelDeps { _ in
      let space = try Space.inMemory()
      let sessions = space.sessions
      let seen = Box<[[TranscriptLine]]>([])
      let committed = AsyncStream<Void>.makeStream()
      defer { committed.continuation.finish() }
      let config = makeConfig(inference: { request in
        seen.withLock { $0.append(request.lines) }
        var reply = Fix.reply("done")
        reply.committed = { _ in committed.continuation.yield(()) }
        return reply
      })
      let service = SessionExecution(space: space, loopConfig: config)
      let parent = try await sessions.createSession(group: .shared, title: "parent", kind: .agent, createdBy: "morgan", model: .test)
      let id = try await sessions.createSession(group: .shared, title: "restart", kind: kind, parent: kind == .task ? parent : nil, createdBy: "morgan", executor: .kernel(.test))
      _ = try await sessions.armSubscription(id, slot: .init(id: .init("timer.keep"), kind: .timer(.cron("* * * * *"), message: "later")), nextFireAt: anchor.addingTimeInterval(60))
      try await sessions.markInterrupted(id)
      try await sessions.enqueue(id, input: Fix.message("waiting before restart"))
      try await runService(service) { service in
        _ = try await service.restart(id, executor: nil, note: "Started over. Catch up before acting.")
        for await _ in committed.stream { break }
        let lines = try #require(seen.value.first)
        #expect(seen.value.count == 1)
        #expect(lines.contains { $0.key.hasPrefix("message:") && $0.text.hasSuffix("\n\nwaiting before restart") })
        let text = lines.filter { $0.role == .user }.map(\.text).joined(separator: "\n")
        #expect(text.contains("active subscriptions: timer.keep"))
        #expect(text.contains("Started over. Catch up before acting."))
        #expect(try await sessions.record(id).errorMessage == nil)
        #expect(try await sessions.generationState(id).generation == 1)
      }
    }
  }
}
