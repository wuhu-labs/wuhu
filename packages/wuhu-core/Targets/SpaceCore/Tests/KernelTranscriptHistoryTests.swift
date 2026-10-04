import Foundation
import GRDB
import GRDBSQLite
import Scratch
import SessionDomain
@testable import SpaceCore
import Testing
import WuhuAI

@Suite struct KernelTranscriptHistoryTests {
  private static func assistant(_ call: String) -> TranscriptItem {
    .assistant(AssistantEntry(
      id: UUID(), timestamp: fixedDate,
      content: [.toolCall(ToolCall(id: call, name: "grep", arguments: .object([:])))],
      stopReason: .stop, usage: .init(inputTokens: 1, outputTokens: 1, totalTokens: 2), toolCallIDs: [:],
    ))
  }

  private static func result(_ call: String) -> TranscriptItem {
    .toolResult(SessionFix.toolResult(callID: call))
  }

  private static func origin(_ key: String, _ generation: Int64, _ position: Int64, _ call: String, _ db: Database) throws -> TranscriptHistoryEntry? {
    try Sessions.kernelHistoryOrigin(key, generation: generation, resultPosition: position, callID: .init(call), in: db)
  }

  @Test func tenThousandResultsUseFixedIndexedWork() async throws {
    let space = try makeSpace()
    try await space.writer.write { db in
      let assistant = Self.assistant("long-call")
      try Sessions.append("long", generation: 0, items: [assistant], in: db)
      try Sessions.append("long", generation: 0, items: (0 ..< 10000).map { _ in Self.result("long-call") }, in: db)
      for position: Int64 in [1, 5000, 10000] {
        var queries: [String] = []
        db.trace { event in
          if case let .statement(statement) = event { queries.append(statement.expandedSQL) }
        }
        let origin = try Self.origin("long", 0, position, "long-call", db)
        db.trace(options: []) { _ in }
        #expect(origin == TranscriptHistoryEntry(position: 0, item: assistant))
        #expect(queries.count == 5)
        var steps: Int32 = 0
        var plans: [String] = []
        for query in queries {
          let statement = try db.makeStatement(sql: query)
          _ = try Row.fetchAll(statement)
          steps += sqlite3_stmt_status(statement.sqliteStatement, SQLITE_STMTSTATUS_VM_STEP, 1)
          #expect(sqlite3_stmt_status(statement.sqliteStatement, SQLITE_STMTSTATUS_FULLSCAN_STEP, 1) == 0)
          #expect(sqlite3_stmt_status(statement.sqliteStatement, SQLITE_STMTSTATUS_SORT, 1) == 0)
          plans += try Row.fetchAll(db, sql: "EXPLAIN QUERY PLAN " + query).map { $0["detail"] as String }
        }
        #expect(steps < 200)
        #expect(plans.contains { $0.contains("session_contents_assistant_history") })
        #expect(plans.contains { $0.contains("session_pointers_by_content") })
        print("KERNEL_ORIGIN position=\(position) vm_steps=\(steps) plans=\(plans)")
      }
    }
  }

  @Test func interleavedSessionsGenerationsAndOwnershipNeverRetry() async throws {
    let space = try makeSpace()
    try await space.writer.write { db in
      let a = Self.assistant("a")
      let b = Self.assistant("b")
      try Sessions.append("one", generation: 0, items: [a], in: db)
      try Sessions.append("two", generation: 8, items: [b, Self.result("b")], in: db)
      try Sessions.append("one", generation: 0, items: [Self.result("a")], in: db)
      #expect(try Self.origin("one", 0, 1, "a", db)?.item == a)
      #expect(try Self.origin("two", 8, 1, "b", db)?.item == b)
      #expect(try Self.origin("one", 8, 1, "a", db) == nil)
      try Sessions.append("one", generation: 0, items: [Self.assistant("other"), Self.result("a")], in: db)
      #expect(try Self.origin("one", 0, 3, "a", db) == nil)
      try Sessions.append("one", generation: 1, items: [Self.result("a")], in: db)
      #expect(try Self.origin("one", 1, 0, "a", db) == nil)
      #expect(try Self.origin("absent", 0, 1, "a", db) == nil)
    }
  }

  @Test(arguments: [false, true]) func compactionUsesResultSourceBoundaryAndCurrentGeneration(keepAssistant: Bool) async throws {
    try await withSessionDeps {
      let space = try makeSpace()
      let store = space.sessions
      let id = try await store.createSession(group: .shared, title: "kernel", kind: .agent, createdBy: "morgan", model: .test)
      let assistant = Self.assistant("carried")
      let result = Self.result("carried")
      try await store.append(id, items: [assistant, result], transcript: Transcript(items: [assistant, result]))
      let omittedLaterAssistant = Self.assistant("carried")
      try await store.append(id, items: [omittedLaterAssistant], transcript: Transcript(items: [assistant, result, omittedLaterAssistant]))
      let head = GenerationHead(id: UUID(), timestamp: fixedDate, summary: "compacted", snapshot: .init())
      let compacted = try await store.writeCompaction(id, head: head, kept: keepAssistant ? 0 ..< 2 : 1 ..< 2)
      #expect(compacted.items == [.generationHead(head)] + (keepAssistant ? [assistant, result] : [result]))
      let fullPage = try await store.transcriptHistory(id)
      #expect(fullPage.entries.map(\.item) == compacted.items)
      #expect(fullPage.origins.isEmpty)
      let resultPage = try await store.transcriptHistory(id, limit: 1)
      #expect(resultPage.entries.map(\.item) == [result])
      #expect(resultPage.origins == (keepAssistant ? [TranscriptHistoryEntry(position: 1, item: assistant)] : []))
      let resultPosition: Int64 = keepAssistant ? 2 : 1
      try await space.writer.read { db throws -> Void in
        #expect(try Self.origin(id.rawValue, 1, resultPosition, "carried", db) == (keepAssistant ? TranscriptHistoryEntry(position: 1, item: assistant) : nil))
        #expect(try Self.origin(id.rawValue, 0, 1, "carried", db)?.item == assistant)
      }
      let tailAssistant = Self.assistant("later")
      try await store.append(id, items: [tailAssistant], transcript: Transcript(items: compacted.items + [tailAssistant]))
      try await space.writer.read { db throws -> Void in
        #expect(try Self.origin(id.rawValue, 1, resultPosition, "carried", db) == (keepAssistant ? TranscriptHistoryEntry(position: 1, item: assistant) : nil))
      }
      let final = try await store.transcript(id)
      #expect(final.items == compacted.items + [tailAssistant])
      try await store.markInterrupted(id)
      _ = try await store.restart(id)
      try await space.writer.read { db throws -> Void in
        #expect(try Self.origin(id.rawValue, 2, 0, "carried", db) == nil)
      }
    }
  }

  @Test func candidateMappedAfterResultIsRejectedWithoutSearchingOlderAssistants() async throws {
    let space = try makeSpace()
    try await space.writer.write { db in
      let older = Self.assistant("wanted")
      let candidate = Self.assistant("wanted")
      try Sessions.append("s", generation: 0, items: [older, candidate, Self.result("wanted")], in: db)
      let content = try #require(try String.fetchOne(db, sql: "SELECT content_id FROM session_pointers WHERE session_id = 's' AND generation = 0 AND position = 2"))
      try db.execute(sql: "INSERT INTO session_pointers VALUES ('s', 1, 0, ?), ('s', 1, 1, ?), ('s', 1, 2, ?)", arguments: [older.id.uuidString.lowercased(), content, candidate.id.uuidString.lowercased()])
      #expect(try Self.origin("s", 1, 1, "wanted", db) == nil)
    }
  }

  @Test func grdbVacuumAndVacuumIntoPreserveOriginOrdering() async throws {
    let folder = try scratchURL("kernel-history-vacuum")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let source = try DatabaseQueue(path: folder.appendingPathComponent("source.sqlite").path)
    let assistant = Self.assistant("vacuum")
    try await source.write { db in
      try db.execute(sql: sessionSchemaSQL + kernelTranscriptHistorySchemaSQL)
      try Sessions.append("gap", generation: 0, items: [Self.assistant("gap")], in: db)
      try Sessions.append("s", generation: 0, items: [assistant], in: db)
      try Sessions.append("other", generation: 0, items: [Self.assistant("other")], in: db)
      try Sessions.append("s", generation: 0, items: (0 ..< 100).map { _ in Self.result("vacuum") }, in: db)
      try db.execute(sql: "DELETE FROM session_contents WHERE session_id = 'gap'")
      #expect(try Self.origin("s", 0, 100, "vacuum", db)?.item == assistant)
    }
    let before = try await source.read { db in try String.fetchAll(db, sql: "SELECT id FROM session_contents ORDER BY rowid") }
    let destination = folder.appendingPathComponent("vacuum-into.sqlite").path
    try await source.writeWithoutTransaction { db in
      print("KERNEL_VACUUM sqlite=\(try String.fetchOne(db, sql: "SELECT sqlite_version()") ?? "unknown")")
      try db.execute(sql: "VACUUM")
      #expect(try String.fetchAll(db, sql: "SELECT id FROM session_contents ORDER BY rowid") == before)
      #expect(try Self.origin("s", 0, 100, "vacuum", db)?.item == assistant)
      try db.execute(sql: "VACUUM INTO ?", arguments: [destination])
    }
    let copy = try DatabaseQueue(path: destination)
    try await copy.read { db throws -> Void in
      #expect(try String.fetchAll(db, sql: "SELECT id FROM session_contents ORDER BY rowid") == before)
      #expect(try Self.origin("s", 0, 100, "vacuum", db)?.item == assistant)
    }
  }
}
