import DeterministicDependencies
import Foundation
import GRDB
import Scratch
import SessionDomain
import struct SpaceContract.PromptSession
import struct SpaceContract.SessionPromptOutput
@testable import SpaceCore
import Testing

// A session's prompt renders the space as of one stored revision,
// which moves only at creation, compaction and Start over.
@Suite(.deterministicDependencies) struct PromptRevisionTests {
  private func edit(_ space: Space, _ id: SessionID, _ tag: String) async throws {
    _ = try await space.writeText("/AGENTS.md", "root \(tag)")
    _ = try await space.writeText("\(SessionHome.path(of: id))/AGENTS.md", "home \(tag)")
    _ = try await space.writeText("/.agents/skills/\(tag)/SKILL.md", "# \(tag)\n\nthe \(tag) skill")
  }

  // The files the prompt of the session's generation reads.
  private func prompt(_ space: Space, _ id: SessionID) async throws -> String {
    guard case let .pending(pending) = try await space.sessions.activatePrompt(id) else { throw Unexpected() }
    let home = try await space.sessionHome(id, at: pending.rev)
    return (home.sections.map(\.text) + home.skills.map(\.description)).joined(separator: "\n")
  }

  @Test func anEditWaitsForTheNextCompaction() async throws {
    try await withSessionDeps {
      let space = try makeSpace()
      let store = space.sessions
      let id = try await store.createSession(group: .shared, title: "t", kind: .agent, createdBy: "morgan", model: .test)
      try await edit(space, id, "one")
      let fresh = try await space.sessionHome(id)
      #expect(fresh.sections.map(\.text).contains("root one"), "without a revision the latest reads")

      let created = try await store.promptRevision(id)
      #expect(created != nil, "creation stores the revision")
      let frozen = try await prompt(space, id)
      // The full markers: a bare "one" matches a handle like guitar-honey-snow.
      #expect(!["root one", "home one", "the one skill"].contains { frozen.contains($0) }, "the edits came after creation")

      try await edit(space, id, "two")
      #expect(try await prompt(space, id) == frozen)
      #expect(try await store.promptRevision(id) == created)

      let head = GenerationHead(id: UUID(), timestamp: fixedDate, summary: "compacted", snapshot: .init(), runningWork: [])
      _ = try await store.writeCompaction(id, head: head, kept: nil)
      let compacted = try await prompt(space, id)
      #expect(compacted.contains("root two") && compacted.contains("home two") && compacted.contains("the two skill"))
      #expect(compacted.contains("the one skill"))

      try await edit(space, id, "three")
      #expect(try await prompt(space, id) == compacted)
      try await store.markInterrupted(id)
      try await store.restart(id)
      #expect(try await prompt(space, id).contains("home three"), "Start over renders the latest")
    }
  }

  @Test func aSessionWithoutARowRendersLatestAndStoresItAtActivation() async throws {
    try await withSessionDeps {
      let space = try makeSpace()
      let store = space.sessions
      let id = try await store.createSession(group: .shared, title: "t", kind: .agent, createdBy: "morgan", model: .test)
      // A session that predates the table.
      try await space.writer.write { db in
        try db.execute(sql: #"DELETE FROM "session_prompts" WHERE session_id = ?"#, arguments: [id.rawValue])
      }
      try await edit(space, id, "one")
      #expect(try await store.promptRevision(id) == nil)
      let first = try await prompt(space, id)
      #expect(first.contains("home one"))
      #expect(try await store.promptRevision(id) != nil)

      try await edit(space, id, "two")
      #expect(try await prompt(space, id) == first)
    }
  }

  @Test func aRevisionBeforeAnyWriteRendersNothing() async throws {
    try await withSessionDeps {
      let space = try makeSpace()
      #expect(try await space.scope(at: "/", in: .shared, rev: 0) == .empty)
    }
  }

  @Test func theRevisionSurvivesAReopen() async throws {
    let folder = try scratchURL("prompt-revision")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let file = folder.appendingPathComponent("space.sqlite")
    try await withSessionDeps {
      let space = try Space.open(file: file)
      let id = try await space.sessions.createSession(group: .shared, title: "t2", kind: .agent, createdBy: "morgan", model: .test)
      let frozen = try await prompt(space, id)
      try await edit(space, id, "two")
      #expect(try await prompt(try Space.open(file: file), id) == frozen, "a restart keeps the prompt")
    }
  }

  @Test func theRenderedPromptIsStoredForTheGenerationAndClearedByACompaction() async throws {
    try await withSessionDeps {
      let space = try makeSpace()
      let store = space.sessions
      let id = try await store.createSession(group: .shared, title: "t", kind: .agent, createdBy: "morgan", model: .test)
      guard case let .pending(pending) = try await store.activatePrompt(id) else { throw Unexpected() }
      let session = PromptSession(try await store.record(id))
      let first = SessionPromptOutput(prompt: "first", session: session)
      #expect(try await store.storePrompt(id, for: pending, first) == first)
      #expect(try await store.storePrompt(id, for: pending, SessionPromptOutput(prompt: "racing", session: session)) == first, "the first stored wins")
      _ = try await store.setTitle(id, to: "renamed")
      #expect(try await store.activatePrompt(id) == .rendered(first))

      try await edit(space, id, "one")
      let head = GenerationHead(id: UUID(), timestamp: fixedDate, summary: "compacted", snapshot: .init(), runningWork: [])
      _ = try await store.writeCompaction(id, head: head, kept: nil)
      guard case let .pending(next) = try await store.activatePrompt(id) else { throw Unexpected() }
      #expect(next.rev > pending.rev)
      let stale = SessionPromptOutput(prompt: "stale", session: session)
      #expect(try await store.storePrompt(id, for: pending, stale) == stale)
      #expect(try await store.activatePrompt(id) == .pending(next), "a render of an older generation is not stored")
    }
  }

  // Session operations write no file, so a rename and a Start over leave the
  // space's revision where it was: only the generation tells the renders apart.
  @Test func aRenderStartedBeforeARenameAndStartOverIsNotStored() async throws {
    try await withSessionDeps {
      let space = try makeSpace()
      let store = space.sessions
      let id = try await store.createSession(group: .shared, title: "old", kind: .agent, createdBy: "morgan", model: .test)
      guard case let .pending(started) = try await store.activatePrompt(id) else { throw Unexpected() }
      let stale = SessionPromptOutput(prompt: "old title", session: PromptSession(try await store.record(id)))

      _ = try await store.setTitle(id, to: "new")
      try await store.markInterrupted(id)
      try await store.restart(id)
      guard case let .pending(restarted) = try await store.activatePrompt(id) else { throw Unexpected() }
      #expect(restarted.rev == started.rev && restarted.generation > started.generation)

      #expect(try await store.storePrompt(id, for: started, stale) == stale)
      #expect(try await store.activatePrompt(id) == .pending(restarted), "the old generation's render is not stored")
    }
  }

  @Test func theUpgradeKeepsEachSessionsRevision() async throws {
    try await withSessionDeps {
      let database = try DatabaseQueue(path: "file:/prompt-upgrade-\(UUID())?vfs=memdb")
      let space = try Space(writer: database)
      let id = try await space.sessions.createSession(group: .shared, title: "t", kind: .agent, createdBy: "morgan", model: .test)
      let rev = try #require(try await space.sessions.promptRevision(id))
      try await database.write { db in
        try db.execute(sql: """
        DROP TABLE "session_prompts";
        CREATE TABLE "session_prompt_revisions" ("session_id" TEXT NOT NULL PRIMARY KEY, "rev" INTEGER NOT NULL);
        DELETE FROM grdb_migrations WHERE identifier = '007';
        """)
        try db.execute(sql: #"INSERT INTO "session_prompt_revisions" VALUES (?, ?)"#, arguments: [id.rawValue, rev])
        try db.execute(sql: #"INSERT INTO "session_prompt_revisions" VALUES ('without-runtime', ?)"#, arguments: [rev])
      }
      let upgraded = try Space(writer: try DatabaseQueue(path: database.path))
      #expect(try await upgraded.sessions.activatePrompt(id) == .pending(PendingPrompt(generation: 0, rev: rev)))
      let kept = try await database.read { db in
        try Row.fetchOne(db, sql: #"SELECT "generation", "rev" FROM "session_prompts" WHERE session_id = 'without-runtime'"#)
          .map { [$0["generation"], $0["rev"]] as [Int] }
      }
      #expect(kept == [0, rev], "a revision without a runtime row is kept at generation 0")
      #expect(try await database.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM sqlite_master WHERE name = 'session_prompt_revisions'") } == 0)
      try await space.close()
      try await upgraded.close()
    }
  }
}

private struct Unexpected: Error {}
