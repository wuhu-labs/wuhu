import Foundation
import GRDB
import Scratch
import SessionDomain
@testable import SpaceCore
import Testing

// A session's prompt renders the space as of one stored revision,
// which moves only at creation, compaction and Start over.
@Suite struct PromptRevisionTests {
  private func edit(_ space: Space, _ id: SessionID, _ tag: String) async throws {
    _ = try await space.writeText("/AGENTS.md", "root \(tag)")
    _ = try await space.writeText("\(SessionHome.path(of: id))/AGENTS.md", "home \(tag)")
    _ = try await space.writeText("/.agents/skills/\(tag)/SKILL.md", "# \(tag)\n\nthe \(tag) skill")
  }

  private func prompt(_ space: Space, _ id: SessionID) async throws -> String {
    let home = try await space.sessionHome(id, at: try await space.sessions.activatePromptRevision(id))
    return home.groupRendered + "\n\n" + home.rendered
  }

  @Test func anEditWaitsForTheNextCompaction() async throws {
    try await withSessionDeps {
      let space = try makeSpace()
      let store = space.sessions
      let id = try await store.createSession(group: .shared, title: "t", kind: .agent, createdBy: "morgan", model: .test)
      try await edit(space, id, "one")
      let fresh = try await space.sessionHome(id)
      #expect(fresh.groupRendered.contains("root one"), "without a revision the latest renders")

      let created = try await store.promptRevision(id)
      #expect(created != nil, "creation stores the revision")
      let frozen = try await prompt(space, id)
      // The full markers: a bare "one" matches a handle like guitar-honey-snow.
      #expect(!["root one", "home one", "the one skill"].contains { frozen.contains($0) }, "the edits came after creation")

      try await edit(space, id, "two")
      #expect(try await prompt(space, id) == frozen)
      #expect(try await store.promptRevision(id) == created)

      let head = GenerationHead(id: UUID(), timestamp: fixedDate, summary: "compacted", snapshot: .init())
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

  @Test func claudeCodesCompactBoundaryAdvancesTheRevision() async throws {
    try await withSessionDeps {
      let space = try makeSpace()
      let store = space.sessions
      let id = try await store.createSession(
        group: .shared,
        title: "claude", kind: .agent, createdBy: "morgan",
        executor: .claudeCode(ModelSpecifier(provider: "claude", model: "opus", effort: "high")),
        snapshot: .init(),
      )
      let created = try #require(try await store.promptRevision(id))
      try await edit(space, id, "one")
      try await store.appendClaudeCodeMirror(id, entries: [["type": "assistant", "uuid": "x0"]])
      #expect(try await store.promptRevision(id) == created, "an ordinary entry leaves the prompt alone")

      try await store.appendClaudeCodeMirror(id, entries: [[
        "type": "system", "subtype": "compact_boundary", "uuid": "b",
        "compactMetadata": ["trigger": "auto", "preservedMessages": ["allUuids": []]],
      ]])
      #expect(try #require(try await store.promptRevision(id)) > created)
      #expect(try await prompt(space, id).contains("home one"))
    }
  }

  @Test func aSessionWithoutARowRendersLatestAndStoresItAtActivation() async throws {
    try await withSessionDeps {
      let space = try makeSpace()
      let store = space.sessions
      let id = try await store.createSession(group: .shared, title: "t", kind: .agent, createdBy: "morgan", model: .test)
      // A session that predates the table.
      try await space.writer.write { db in
        try db.execute(sql: #"DELETE FROM "session_prompt_revisions" WHERE session_id = ?"#, arguments: [id.rawValue])
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

  @Test func theRevisionSurvivesAReopenAndAnOldDatabaseGainsTheTable() async throws {
    let folder = try scratchURL("prompt-revision")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let file = folder.appendingPathComponent("space.sqlite")
    try await withSessionDeps {
      let space = try Space.open(file: file)
      let id = try await space.sessions.createSession(group: .shared, title: "t", kind: .agent, createdBy: "morgan", model: .test)
      let old = try await space.sessions.createSession(group: .shared, title: "old", kind: .agent, createdBy: "morgan", model: .test)
      let frozen = try await prompt(space, id)
      try await edit(space, id, "one")
      // A database from before prompt revisions: the table does not exist yet.
      try await space.writer.write { db in try db.execute(sql: #"DROP TABLE "session_prompt_revisions""#) }

      let reopened = try Space.open(file: file)
      #expect(try await reopened.sessions.promptRevision(id) == nil, "no backfill")
      #expect(try await prompt(reopened, old).contains("root one"), "a session without a row renders the latest")
      #expect(frozen != (try await prompt(reopened, id)))
    }
    try await withSessionDeps {
      let space = try Space.open(file: file)
      let id = try await space.sessions.createSession(group: .shared, title: "t2", kind: .agent, createdBy: "morgan", model: .test)
      let frozen = try await prompt(space, id)
      try await edit(space, id, "two")
      #expect(try await prompt(try Space.open(file: file), id) == frozen, "a restart keeps the prompt")
    }
  }
}
