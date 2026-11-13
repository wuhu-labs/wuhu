import DeterministicDependencies
import Foundation
@testable import LoopCore
import Scratch
import SessionDomain
import struct SpaceContract.PromptSession
@testable import SpaceCore
import Testing

@Suite(.deterministicDependencies) struct PromptRevisionTests {
  private func edit(_ space: Space, _ id: SessionID, _ tag: String) async throws {
    try await space.writeHandlerText("/AGENTS.md", "root \(tag)")
    try await space.writeHandlerText("\(SessionHome.path(of: id))/AGENTS.md", "home \(tag)")
    try await space.writeHandlerText("/.agents/skills/\(tag)/SKILL.md", "# \(tag)\n\nthe \(tag) skill")
  }

  // The files the prompt of the session's generation reads.
  private func prompt(_ space: Space, _ id: SessionID) async throws -> String {
    let reference = try await space.sessions.promptForInference(id)
    await space.sessions.noMail(id)
    guard case let .pending(pending) = reference else { throw Unexpected() }
    let home = try await space.sessionHome(id, at: pending.revs)
    return (home.sections.map(\.text) + home.skills.map(\.description)).joined(separator: "\n")
  }

  @Test func anEditWaitsForTheNextCompaction() async throws {
    try await withSessionHandlerDeps {
      let space = try makeHandlerSpace()
      let store = space.sessions
      let id = try await store.createSession(group: .shared, title: "t", kind: .agent, createdBy: "morgan", model: .test)
      try await edit(space, id, "one")
      let fresh = try await space.sessionHome(id)
      #expect(fresh.sections.map(\.text).contains("root one"), "without a revision the latest reads")

      #expect(try await store.promptRevisions(id) == nil, "capture waits for first inference")
      let frozen = try await prompt(space, id)
      // The full markers: a bare "one" matches a handle like guitar-honey-snow.
      #expect(["root one", "home one", "the one skill"].allSatisfy { frozen.contains($0) })
      let created = try await store.promptRevisions(id)

      try await edit(space, id, "two")
      #expect(try await prompt(space, id) == frozen)
      #expect(try await store.promptRevisions(id) == created)

      let head = GenerationHead(id: UUID(), timestamp: handlerDate, summary: "compacted", snapshot: .init(), runningWork: [])
      _ = try await space.worker.call(SessionCell.ID(id.rawValue)) { try $0.writeGeneration(id, head: head) }
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
    try await withSessionHandlerDeps {
      let space = try makeHandlerSpace()
      let store = space.sessions
      let id = try await store.createSession(group: .shared, title: "t", kind: .agent, createdBy: "morgan", model: .test)
      try await edit(space, id, "one")
      #expect(try await store.promptRevisions(id) == nil)
      let first = try await prompt(space, id)
      #expect(first.contains("home one"))
      #expect(try await store.promptRevisions(id) != nil)

      try await edit(space, id, "two")
      #expect(try await prompt(space, id) == first)
    }
  }

  @Test func aRevisionBeforeAnyWriteRendersNothing() async throws {
    try await withSessionHandlerDeps {
      let space = try makeHandlerSpace()
      #expect(try await space.scope(at: "/", in: .shared, rev: 0) == .empty)
    }
  }

  @Test func theRevisionSurvivesAReopen() async throws {
    let folder = try scratchURL("prompt-revision")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let file = folder.appendingPathComponent("space.sqlite")
    try await withSessionHandlerDeps {
      let space = registerHandlerSessions(try Space.open(file: file))
      let id = try await space.sessions.createSession(group: .shared, title: "t2", kind: .agent, createdBy: "morgan", model: .test)
      let frozen = try await prompt(space, id)
      try await edit(space, id, "two")
      try await space.close()
      let reopened = registerHandlerSessions(try Space.open(file: file))
      #expect(try await prompt(reopened, id) == frozen, "a restart keeps the prompt")
      try await reopened.close()
    }
  }

  @Test func theRenderedPromptIsStoredForTheGenerationAndClearedByACompaction() async throws {
    try await withSessionHandlerDeps {
      let space = try makeHandlerSpace()
      let store = space.sessions
      let id = try await store.createSession(group: .shared, title: "t", kind: .agent, createdBy: "morgan", model: .test)
      guard case let .pending(pending) = try await store.promptForInference(id) else { throw Unexpected() }
      let session = PromptSession(try await store.record(id))
      let first = try await store.storeInferencePrompt(id, for: pending, "first", tools: [], session: session)
      await store.noMail(id)
      #expect(first.preamble == .init(system: "first", tools: []))
      #expect(try await store.storeInferencePrompt(id, for: pending, "racing", tools: [], session: session) == first, "the first stored wins")
      _ = try await space.worker.call(SessionCell.ID(id.rawValue)) { try $0.retitle("renamed") }
      #expect(try await store.promptForInference(id) == .rendered(first))

      try await edit(space, id, "one")
      let head = GenerationHead(id: UUID(), timestamp: handlerDate, summary: "compacted", snapshot: .init(), runningWork: [])
      _ = try await space.worker.call(SessionCell.ID(id.rawValue)) { try $0.writeGeneration(id, head: head) }
      guard case let .pending(next) = try await store.promptForInference(id) else { throw Unexpected() }
      #expect(next.revs["shared"]! > pending.revs["shared"]!)
      #expect(try await store.storeInferencePrompt(id, for: pending, "stale", tools: [], session: session).preamble.system == "stale")
      await store.noMail(id)
      #expect(try await store.promptForInference(id) == .pending(next), "a render of an older generation is not stored")
    }
  }

  // Session operations write no file, so a rename and a Start over leave the
  // space's revision where it was: only the generation tells the renders apart.
  @Test func aRenderStartedBeforeARenameAndStartOverIsNotStored() async throws {
    try await withSessionHandlerDeps {
      let space = try makeHandlerSpace()
      let store = space.sessions
      let id = try await store.createSession(group: .shared, title: "old", kind: .agent, createdBy: "morgan", model: .test)
      guard case let .pending(started) = try await store.promptForInference(id) else { throw Unexpected() }
      let stale = PromptSession(try await store.record(id))

      _ = try await space.worker.call(SessionCell.ID(id.rawValue)) { try $0.retitle("new") }
      try await store.markInterrupted(id)
      try await store.restart(id)
      guard case let .pending(restarted) = try await store.promptForInference(id) else { throw Unexpected() }
      #expect(restarted.revs == started.revs && restarted.generation > started.generation)

      #expect(try await store.storeInferencePrompt(id, for: started, "old title", tools: [], session: stale).session == stale)
      await store.noMail(id)
      #expect(try await store.promptForInference(id) == .pending(restarted), "the old generation's render is not stored")
    }
  }
}

private struct Unexpected: Error {}
