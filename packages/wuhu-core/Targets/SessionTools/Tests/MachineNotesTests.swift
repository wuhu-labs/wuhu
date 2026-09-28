import Foundation
import GRDB
import JSONValue
import SessionDomain
@testable import SessionTools
import struct SpaceContract.GroupID
@testable import SpaceCore
import Testing

private let deploySkill = """
---
description: Ship it to the fleet.
---

# Deploy
"""

private func box() -> FakeMachineFS {
  let machineFS = FakeMachineFS()
  machineFS.put("/work/repo/.git/HEAD", "ref: refs/heads/main", mtime: 1)
  machineFS.put("/work/repo/AGENTS.md", "repo manual", mtime: 1)
  machineFS.put("/work/repo/README.md", "readme", mtime: 1)
  machineFS.put("/work/loose/a.txt", "loose", mtime: 1)
  machineFS.put("/tmp/b.txt", "tmp", mtime: 1)
  return machineFS
}

private func writeNotes(_ space: Space, _ alias: String) async throws {
  _ = try await space.fs(.shared).write("/_/machines/\(alias)/AGENTS.md", Data("\(alias) manual".utf8), ifMatch: nil)
  _ = try await space.fs(.shared).write("/_/machines/\(alias)/.agents/skills/deploy/SKILL.md", Data(deploySkill.utf8), ifMatch: nil)
}

private func touch(_ world: inout ToolWorld, _ address: String) async throws -> String {
  guard case .read = try await world.run("read", .object(["path": .string(address)])) else {
    throw Mismatch("read \(address) failed")
  }
  return world.delivered?.text ?? ""
}

@Suite struct MachineNotesTests {
  @Test func theFirstTouchOfAMachineDeliversItsNotesOnceAheadOfTheRepository() async throws {
    try await withToolDeps { _ in
      let space = try Space.inMemory()
      let folder = "/_/machines/\(try await space.addMachine(name: "studio").id.rawValue)"
      try await writeNotes(space, "studio")
      var world = ToolWorld(executor: ToolExecutor(space: space, machines: box().seam), session: try await makeSession(space))

      let first = try await touch(&world, "machines://studio/work/repo/README.md")
      let notes = try #require(first.range(of: "<AGENTS.md from=\"\(folder)/AGENTS.md\">\nstudio manual\n</AGENTS.md>"))
      let skills = try #require(first.range(of: """
      skills (read the path before using one):
      - deploy — Ship it to the fleet. (\(folder)/.agents/skills/deploy/SKILL.md)
      """))
      let repo = try #require(first.range(of: "repo manual"))
      #expect(notes.upperBound <= skills.lowerBound)
      #expect(skills.upperBound <= repo.lowerBound)

      #expect(try await touch(&world, "machines://studio/work/loose/a.txt").isEmpty)
      #expect(try await touch(&world, "machines://studio/tmp/b.txt").isEmpty)
    }
  }

  @Test func notesComeFromTheMachinesGroupQualifiedOutsideTheSessions() async throws {
    try await withToolDeps { _ in
      let space = try Space.inMemory()
      let alice = GroupID(rawValue: "alice")
      try await space.writer.write { db in
        try db.execute(sql: "INSERT INTO groups (id, created_at) VALUES ('alice', '2026-01-01T00:00:00.000Z')")
      }
      try await space.addEdge(src: alice, dst: .shared, kind: .read, by: nil)
      let studio = try await space.addMachine(name: "studio").id.rawValue
      let mini = try await space.addMachine(name: "mini").id.rawValue
      try await space.writer.write { db in
        try db.execute(sql: "UPDATE machines SET grp = 'alice' WHERE id = ?", arguments: [mini])
      }
      try await writeNotes(space, "studio")
      _ = try await space.fs(alice).write("/_/machines/\(mini)/AGENTS.md", Data("mini manual".utf8), ifMatch: nil)
      let session = try await makeSession(space, group: alice)
      var world = ToolWorld(executor: ToolExecutor(space: space, machines: box().seam), session: session)

      let shared = try await touch(&world, "machines://studio/tmp/b.txt")
      #expect(shared.contains("<AGENTS.md from=\"wuhu://shared.localspace/_/machines/\(studio)/AGENTS.md\">\nstudio manual"))
      #expect(shared.contains("(wuhu://shared.localspace/_/machines/\(studio)/.agents/skills/deploy/SKILL.md)"))
      let own = try await touch(&world, "machines://mini/tmp/b.txt")
      #expect(own.contains("<AGENTS.md from=\"/_/machines/\(mini)/AGENTS.md\">\nmini manual"))
    }
  }

  @Test func theNameAndTheIdShareOneDelivery() async throws {
    try await withToolDeps { _ in
      let space = try Space.inMemory()
      let studio = try await space.addMachine(name: "studio")
      try await writeNotes(space, "studio")
      var world = ToolWorld(executor: ToolExecutor(space: space, machines: box().seam), session: try await makeSession(space))

      #expect(try await touch(&world, "machines://\(studio.id.rawValue)/tmp/b.txt").contains("studio manual"))
      #expect(try await touch(&world, "machines://studio/work/loose/a.txt").isEmpty)
    }
  }

  @Test func eachMachineDeliversItsOwnNotes() async throws {
    try await withToolDeps { _ in
      let space = try Space.inMemory()
      _ = try await space.addMachine(name: "studio")
      _ = try await space.addMachine(name: "mini")
      try await writeNotes(space, "studio")
      try await writeNotes(space, "mini")
      var world = ToolWorld(executor: ToolExecutor(space: space, machines: box().seam), session: try await makeSession(space))

      let studio = try await touch(&world, "machines://studio/tmp/b.txt")
      #expect(studio.contains("studio manual"))
      #expect(!studio.contains("mini manual"))
      let mini = try await touch(&world, "machines://mini/tmp/b.txt")
      #expect(mini.contains("mini manual"))
      #expect(!mini.contains("studio manual"))
    }
  }

  @Test func aMissingFolderDeliversNothingAndTheTouchStillCounts() async throws {
    try await withToolDeps { _ in
      let space = try Space.inMemory()
      _ = try await space.addMachine(name: "studio")
      var world = ToolWorld(executor: ToolExecutor(space: space, machines: box().seam), session: try await makeSession(space))

      #expect(try await touch(&world, "machines://studio/tmp/b.txt").isEmpty)
      try await writeNotes(space, "studio")
      #expect(try await touch(&world, "machines://studio/work/loose/a.txt").isEmpty)
    }
  }

  @Test func anEmptyFolderDeliversNothing() async throws {
    try await withToolDeps { _ in
      let space = try Space.inMemory()
      _ = try await space.addMachine(name: "studio")
      _ = try await space.fs(.shared).write("/_/machines/studio/.agents/skills/empty/notes.md", Data("x".utf8), ifMatch: nil)
      var world = ToolWorld(executor: ToolExecutor(space: space, machines: box().seam), session: try await makeSession(space))

      #expect(try await touch(&world, "machines://studio/tmp/b.txt").isEmpty)
    }
  }

  @Test func aCompactionDeliversTheNotesAgainOnTheNextTouch() async throws {
    try await withToolDeps { _ in
      let space = try Space.inMemory()
      _ = try await space.addMachine(name: "studio")
      try await writeNotes(space, "studio")
      var world = ToolWorld(executor: ToolExecutor(space: space, machines: box().seam), session: try await makeSession(space))

      #expect(try await touch(&world, "machines://studio/tmp/b.txt").contains("studio manual"))
      _ = try await space.fs(.shared).write("/_/machines/studio/AGENTS.md", Data("edited manual".utf8), ifMatch: nil)
      #expect(try await touch(&world, "machines://studio/work/loose/a.txt").isEmpty)

      world.state = ToolExecutionState(resuming: StateSnapshot(carrying: world.state, preReads: []))
      #expect(try await touch(&world, "machines://studio/tmp/b.txt").contains("edited manual"))
    }
  }

  @Test func aMachineWithoutANameKeepsItsNotesUnderItsId() async throws {
    try await withToolDeps { _ in
      let space = try Space.inMemory()
      let bare = try await space.addMachine(name: nil)
      try await writeNotes(space, bare.id.rawValue)
      var world = ToolWorld(executor: ToolExecutor(space: space, machines: box().seam), session: try await makeSession(space))

      #expect(try await touch(&world, "machines://\(bare.id.rawValue)/tmp/b.txt").contains("\(bare.id.rawValue) manual"))
    }
  }

  @Test func aRenameKeepsTheNotes() async throws {
    try await withToolDeps { _ in
      let space = try Space.inMemory()
      let studio = try await space.addMachine(name: "studio")
      try await writeNotes(space, "studio")
      _ = try await space.renameMachine(studio.id, name: "atelier")
      var world = ToolWorld(executor: ToolExecutor(space: space, machines: box().seam), session: try await makeSession(space))

      #expect(try await touch(&world, "machines://atelier/tmp/b.txt").contains("studio manual"))
      #expect(try await space.readTextForTest("/_/machines/atelier/AGENTS.md") == "studio manual")
      await #expect(throws: SpaceError.notFound("/_/machines/studio/AGENTS.md")) {
        try await space.fs(.shared).read("/_/machines/studio/AGENTS.md")
      }
    }
  }

  @Test func theFileToolsReachTheNotesByNameOrId() async throws {
    try await withToolDeps { _ in
      let space = try Space.inMemory()
      let id = try await space.addMachine(name: "studio").id.rawValue
      var world = ToolWorld(executor: ToolExecutor(space: space, machines: box().seam), session: try await makeSession(space))

      guard case .write = try await world.run("write", .object(["path": "/_/machines/studio/AGENTS.md", "content": "v1"])) else {
        throw Mismatch("a session writes a machine's notes by its name")
      }
      guard case let .read(read) = try await world.run("read", .object(["path": .string("/_/machines/\(id)/AGENTS.md")])) else {
        throw Mismatch("the id reaches the same file")
      }
      #expect(read.content == "v1")
      guard case .edit = try await world.run("edit", .object([
        "path": .string("/_/machines/\(id)/AGENTS.md"),
        "edits": .array([.object(["old": "v1", "new": "v2"])]),
      ])) else {
        throw Mismatch("an edit by the id lands")
      }
      #expect(try await space.readTextForTest("/_/machines/studio/AGENTS.md") == "v2")

      let ghost = try await world.run("write", .object(["path": "/_/machines/ghost/AGENTS.md", "content": "x"]))
      _ = try failureMessage(ghost)
      #expect(try await space.fs(.shared).list("/_/machines").1.map(\.name) == ["studio"])
    }
  }
}
