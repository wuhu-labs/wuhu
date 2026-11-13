import struct Credentials.CredentialResolver
import Dependencies
import DeterministicDependencies
import Fetch
import Foundation
import JSONValue
import LoopCore
import struct SessionDomain.ModelSpecifier
import enum SessionDomain.SessionExecutor
import struct SessionDomain.SessionID
import SpaceCore
import Synchronization
import Testing

@Suite(.deterministicDependencies) struct HomeWriteRuleTests {
  private func contents(_ harness: SessionHarness, _ path: String) async throws -> String {
    String(decoding: try await harness.space.fs(.shared).read(path).1, as: UTF8.self)
  }

  @Test func onlyTheOwnerAndHumansWriteIntoASessionHome() async throws {
    try await withSessionDeps {
      let harness = try await SessionHarness()
      let parent = try await harness.createSession().rawValue
      let owner = try await harness.store.createSession(
        group: .shared,
        title: "child",
        kind: .task,
        parent: SessionID(parent),
        createdBy: "morgan",
        executor: .kernel(ModelSpecifier(provider: "claude", model: "opus", effort: "high")),
      ).rawValue
      let note = "/_/sessions/\(owner)/note.md"

      let own = try await callResult(harness, owner, tool: "write", .object(["path": .string(note), "content": "mine\n"]))
      #expect(!isToolError(own), "\(resultText(own) ?? "")")
      #expect(try await contents(harness, note) == "mine\n")

      _ = try await callResult(harness, parent, tool: "read", .object(["path": .string(note)]))
      let attempts: [(String, JSONValue)] = [
        ("write", .object(["path": .string(note), "content": "parent's\n"])),
        ("edit", .object(["path": .string(note), "edits": [["old": "mine", "new": "parent's"]]])),
        ("write", .object(["path": .string("/_/sessions/\(owner)/planted.md"), "content": "x"])),
      ]
      for (tool, arguments) in attempts {
        let refused = try await callResult(harness, parent, tool: tool, arguments)
        #expect(isToolError(refused), "\(tool) \(arguments.jsonString())")
        #expect(resultText(refused)?.contains("propose the change to \(owner) by message") == true)
      }
      #expect(try await contents(harness, note) == "mine\n")
      await #expect(throws: (any Error).self) { try await harness.space.fs(.shared).read("/_/sessions/\(owner)/planted.md") }

      let ownHome = try await callResult(
        harness, parent, tool: "write",
        .object(["path": .string("/_/sessions/\(parent)/note.md"), "content": "parent's own\n"]),
      )
      #expect(!isToolError(ownHome))

      let human = try await harness.post("/v1/tools/write", .object(["path": .string(note), "content": "human\n"]))
      #expect(human.status == .ok)
      #expect(try await contents(harness, note) == "human\n")
      let phone = try await harness.put("/v1/f/_/sessions/\(owner)/phone.md", .string("phone"))
      #expect(phone.status == .ok)
      #expect(try await contents(harness, "/_/sessions/\(owner)/phone.md").contains("phone"))
    }
  }

  @Test func everySessionAndEveryHumanWritesMachineNotes() async throws {
    try await withSessionDeps {
      let harness = try await SessionHarness()
      _ = (try await harness.space.addMachineV2(name: "studio")).machine
      let first = try await harness.createSession().rawValue
      let second = try await harness.createSession().rawValue
      let notes = "/_/machines/studio/AGENTS.md"

      let written = try await callResult(harness, first, tool: "write", .object(["path": .string(notes), "content": "first\n"]))
      #expect(!isToolError(written), "\(resultText(written) ?? "")")
      _ = try await callResult(harness, second, tool: "read", .object(["path": .string(notes)]))
      let edited = try await callResult(
        harness, second, tool: "edit", .object(["path": .string(notes), "edits": [["old": "first", "new": "second"]]]),
      )
      #expect(!isToolError(edited), "\(resultText(edited) ?? "")")
      #expect(try await contents(harness, notes) == "second\n")

      let phone = try await harness.put("/v1/f/_/machines/studio/.agents/skills/deploy/SKILL.md", .string("# Deploy"))
      #expect(phone.status == .ok)
      #expect(try await contents(harness, "/_/machines/studio/.agents/skills/deploy/SKILL.md").contains("Deploy"))

      for path in ["/_/machines/studio", "/_/machines", "/_/machines/ghost/AGENTS.md", "/_/elsewhere/note.md"] {
        let refused = try await callResult(harness, first, tool: "write", .object(["path": .string(path), "content": "x"]))
        #expect(isToolError(refused), "\(path)")
      }
    }
  }
}
