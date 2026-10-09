import Dependencies
import Foundation
import GRDB
@testable import LoopCore
import SessionDomain
@testable import SpaceCore
import Testing

@Suite(.timeLimit(.minutes(1))) struct StartOverTests {
  @Test func corruptQueuedRowDoesNotReErrorAndReadableRowsReachOneFreshTurn() async throws {
    try await withKernelDeps { _ in
      let space = try Space.inMemory()
      let sessions = space.sessions
      let id = try await sessions.createSession(group: .shared, title: "queue recovery", kind: .agent, createdBy: "morgan", model: .test)
      _ = try await sessions.enqueue(id, input: Fix.message("first", message: "first"))
      _ = try await sessions.enqueue(id, input: Fix.message("bad", message: "bad"))
      _ = try await sessions.enqueue(id, input: Fix.message("last", message: "last"))
      try await space.writer.write { db in
        try db.execute(sql: "UPDATE session_queue SET payload = '{}' WHERE session_id = ? AND id = 2", arguments: [id.rawValue])
      }
      try await sessions.markErrored(id, message: "bad queue")
      let seen = Box<[Transcript]>([])
      let committed = AsyncStream<Void>.makeStream()
      defer { committed.continuation.finish() }
      try await runService(sessions, makeConfig(inference: { request in
        seen.withLock { $0.append(request.transcript) }
        var reply = Fix.reply("recovered")
        reply.committed = { _, _ in committed.continuation.yield(()) }
        return reply
      })) { service in
        _ = try await service.restart(id, executor: nil, note: "Started over.")
        for await _ in committed.stream { break }
        #expect(seen.value.count == 1)
        let transcript = try #require(seen.value.first)
        let messages = transcript.items.compactMap { item -> String? in
          if case let .message(message) = item { return message.content.text }; return nil
        }
        #expect(messages == ["first", "last"])
        #expect(try await sessions.record(id).errorMessage == nil)
        #expect(try await sessions.generationState(id).note?.contains("Dropped 1 queued input(s)") == true)
        try await service.archive(id)
      }
    }
  }

  @Test(arguments: [SessionKind.agent, .task])
  func queuedInputWakesTheNewGenerationAndItsFirstPromptCarriesState(kind: SessionKind) async throws {
    try await withKernelDeps { _ in
      let sessions = try Space.inMemory().sessions
      let parent = try await sessions.createSession(group: .shared, title: "parent", kind: .agent, createdBy: "morgan", model: .test)
      let id = try await sessions.createSession(group: .shared, title: "restart", kind: kind, parent: kind == .task ? parent : nil, createdBy: "morgan", executor: .kernel(.test))
      _ = try await sessions.armSubscription(id, slot: .init(id: .init("timer.keep"), kind: .timer(.cron("* * * * *"), message: "later")), nextFireAt: anchor.addingTimeInterval(60))
      try await sessions.markInterrupted(id)
      _ = try await sessions.enqueue(id, input: Fix.message("waiting before restart"))
      let seen = Box<[Transcript]>([])
      let committed = AsyncStream<Void>.makeStream()
      defer { committed.continuation.finish() }
      let config = makeConfig(inference: { request in
        seen.withLock { $0.append(request.transcript) }
        var reply = Fix.reply("done")
        reply.committed = { _, _ in committed.continuation.yield(()) }
        return reply
      })
      try await runService(sessions, config) { service in
        _ = try await service.restart(id, executor: nil, note: "Started over. Catch up before acting.")
        for await _ in committed.stream { break }
        let transcript = try #require(seen.value.first)
        #expect(seen.value.count == 1)
        #expect(transcript.environment.tools.subscriptions[.init("timer.keep")] == .timer(.cron("* * * * *")))
        #expect(transcript.items.contains { if case let .message(message) = $0 { return message.content.text == "waiting before restart" }; return false })
        let rendered = await transcript.renderRequest(session: id, systemPrompt: "test")
        let text = rendered.messages.compactMap(\.user).flatMap(\.content).compactMap { block -> String? in
          if case let .text(text) = block { return text.text }; return nil
        }.joined(separator: "\n")
        #expect(text.contains("active subscriptions: timer.keep"))
        #expect(text.contains("Started over. Catch up before acting."))
        #expect(try await sessions.record(id).errorMessage == nil)
        #expect(try await sessions.generationState(id).generation == 1)
      }
    }
  }
}
