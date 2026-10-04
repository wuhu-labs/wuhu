import Dependencies
import Foundation
import GRDB
import SessionDomain
@testable import SpaceCore
import Testing
import WuhuAI

@Suite struct TranscriptHistoryTests {
  @Test func pagesAreBoundedExclusiveAndMatchTheCanonicalTranscript() async throws {
    try await withSessionDeps {
      let store = try makeSpace().sessions
      let id = try await store.createSession(group: .shared, title: "history", kind: .agent, createdBy: "owner", model: .test)
      for index in 0 ..< 405 {
        try await store.appendAssistant(id, attemptID: UUID(), message: SessionFix.assistant("entry \(index)"), metadata: SessionFix.metadata)
      }
      let full = try await store.transcriptSnapshot(id)
      let tail = try await store.transcriptHistory(id)
      #expect(tail.entries.count == 200)
      #expect(tail.entries.map(\.position) == Array(205 ..< 405))
      #expect(tail.entries.map(\.item) == Array(full.items.suffix(200)))
      #expect(tail.before == 205)
      #expect(tail.hasEarlier)
      #expect(tail.headPosition == 404)
      let middle = try await store.transcriptHistory(id, generation: tail.generation, before: tail.before)
      #expect(middle.entries.map(\.position) == Array(5 ..< 205))
      #expect(middle.hasEarlier)
      let first = try await store.transcriptHistory(id, generation: tail.generation, before: middle.before)
      #expect(first.entries.map(\.position) == Array(0 ..< 5))
      #expect(!first.hasEarlier)
      let empty = try await store.transcriptHistory(id, generation: tail.generation, before: 0)
      #expect(empty.entries.isEmpty)
      #expect(!empty.hasEarlier)
    }
  }

  @Test func aBoundaryResultGetsAttributionWithoutExpandingThePage() async throws {
    try await withSessionDeps {
      let store = try makeSpace().sessions
      let id = try await store.createSession(group: .shared, title: "history", kind: .agent, createdBy: "owner", model: .test)
      try await store.appendAssistant(id, attemptID: UUID(), message: SessionFix.assistant("calling", toolCalls: [ToolCall(id: "call", name: "exec", arguments: .object(["command": "ls"]))]), metadata: SessionFix.metadata)
      let transcript = try await store.transcript(id)
      guard case let .assistant(assistant) = transcript.items.last else {
        Issue.record("expected minted assistant call")
        return
      }
      let callID = try #require(assistant.toolCalls.first?.id)
      try await store.writeToolResult(id, SessionFix.toolResult(callID: callID))
      let page = try await store.transcriptHistory(id, limit: 1)
      #expect(page.entries.map(\.position) == [1])
      #expect(page.origins.map(\.position) == [0])
      #expect(page.hasEarlier)
      #expect(page.before == 1)
    }
  }

  @Test func invalidAndStaleCursorsNeverReadAnotherGeneration() async throws {
    try await withSessionDeps {
      let store = try makeSpace().sessions
      let id = try await store.createSession(group: .shared, title: "history", kind: .agent, createdBy: "owner", model: .test)
      await #expect(throws: TranscriptHistoryError.invalidPage) { _ = try await store.transcriptHistory(id, limit: 201) }
      await #expect(throws: TranscriptHistoryError.invalidPage) { _ = try await store.transcriptHistory(id, before: 1) }
      let tail = try await store.transcriptHistory(id)
      #expect(tail.entries.isEmpty)
      #expect(tail.headPosition == nil)
      _ = try await store.restart(id)
      await #expect(throws: TranscriptHistoryError.generationChanged(expected: 0, actual: 1)) {
        _ = try await store.transcriptHistory(id, generation: 0, before: 0)
      }
    }
  }
}

@Suite struct BoundedHistoryReadProofTests {
  @Test func recentAndBackwardPagesDoNotDecodeUnselectedAncientPayloads() async throws {
    try await withSessionDeps {
      let space = try makeSpace()
      let store = space.sessions
      let id = try await store.createSession(group: .shared, title: "bounded", kind: .agent, createdBy: "owner", model: .test)
      for index in 0 ..< 405 { try await store.appendAssistant(id, attemptID: UUID(), message: SessionFix.assistant("entry \(index)"), metadata: SessionFix.metadata) }
      try await space.writer.write { db in
        try db.execute(sql: "UPDATE session_contents SET payload = '{\"unexpected\":true}' WHERE session_id = ? AND id = (SELECT content_id FROM session_pointers WHERE session_id = ? AND generation = 0 AND position = 0)", arguments: [id.rawValue, id.rawValue])
      }
      let tail = try await store.transcriptHistory(id)
      #expect(tail.entries.count == 200)
      let older = try await store.transcriptHistory(id, generation: tail.generation, before: tail.before)
      #expect(older.entries.map(\.position) == Array(5 ..< 205))
      await #expect(throws: (any Error).self) { _ = try await store.transcriptSnapshot(id) }
    }
  }

  @Test func snapshotToStreamRaceReplaysFromItsExactHead() async throws {
    try await withSessionDeps {
      let store = try makeSpace().sessions
      let id = try await store.createSession(group: .shared, title: "race", kind: .agent, createdBy: "owner", model: .test)
      try await store.appendAssistant(id, attemptID: UUID(), message: SessionFix.assistant("first"), metadata: SessionFix.metadata)
      let tail = try await store.transcriptHistory(id)
      try await store.appendAssistant(id, attemptID: UUID(), message: SessionFix.assistant("raced"), metadata: SessionFix.metadata)
      var stream = store.observeTranscript(id, from: TranscriptCursor(generation: tail.generation, position: try #require(tail.headPosition)), bounded: true).makeAsyncIterator()
      let replay = try #require(try await stream.next())
      #expect(!replay.reset)
      #expect(replay.startPosition == 1)
      #expect(replay.items.count == 1)
      #expect(replay.items.first == (try await store.transcriptHistory(id, limit: 1)).entries.first?.item)
    }
  }
}
