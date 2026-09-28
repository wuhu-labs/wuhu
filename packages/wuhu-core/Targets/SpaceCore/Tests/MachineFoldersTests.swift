import Foundation
import struct SpaceContract.GroupID
@testable import SpaceCore
import SpaceFS
import Testing

private func text(_ fs: any SpaceVFS, _ path: String) async throws -> String {
  String(decoding: try await fs.read(path).1, as: UTF8.self)
}

@Suite
struct MachineFoldersTests {
  // Notes live with the machine's current group: a move carries them into the
  // new group's tree, where they are listed and delivered, and out of the old.
  @Test func aMovedMachineTakesItsNotesIntoItsNewGroup() async throws {
    let space = try makeSpace()
    let alice = GroupID(rawValue: "alice")
    try await space.writer.write { db in
      try db.execute(sql: "INSERT INTO groups (id, created_at) VALUES ('alice', '2026-01-01T00:00:00.000Z')")
    }
    let machine = try await space.addMachine(name: "studio", group: alice)
    let id = machine.id.rawValue
    let hers = await space.fs(alice)
    let shared = await space.fs(.shared)
    _ = try await hers.write("/_/machines/studio/AGENTS.md", Data("notes".utf8), ifMatch: nil)
    _ = try await hers.write("/_/machines/studio/.agents/skills/x/SKILL.md", Data("skill".utf8), ifMatch: nil)
    _ = try await shared.write("/_/machines/studio/AGENTS.md", Data("stale".utf8), ifMatch: nil)
    #expect(try await hers.list("/_/machines").1.map(\.name) == ["studio"])
    #expect(try await shared.list("/_/machines").1.isEmpty)

    #expect(try await space.moveMachine(machine.id, to: .shared).group == .shared)
    #expect(try await text(shared, "/_/machines/studio/AGENTS.md") == "notes")
    #expect(try await text(shared, "/_/machines/studio/.agents/skills/x/SKILL.md") == "skill")
    #expect(try await shared.list("/_/machines").1.map(\.name) == ["studio"])
    #expect(try await hers.list("/_/machines").1.isEmpty)
    await #expect(throws: SpaceError.notFound("/_/machines/\(id)/AGENTS.md")) {
      _ = try await hers.read("/_/machines/studio/AGENTS.md")
    }
    let delivered = try await space.scope(at: "/_/machines/\(id)", in: .shared)
    #expect(delivered.sections.map(\.text).contains { $0.contains("notes") })
    #expect(try await space.scope(at: "/_/machines/\(id)", in: alice).sections.isEmpty)

    // Moving back carries them back; a move to the current group moves nothing.
    _ = try await space.moveMachine(machine.id, to: alice)
    _ = try await space.moveMachine(machine.id, to: alice)
    #expect(try await text(hers, "/_/machines/studio/AGENTS.md") == "notes")
    #expect(try await hers.list("/_/machines/studio").1.map(\.name).sorted() == [".agents", "AGENTS.md"])
    #expect(try await shared.list("/_/machines").1.isEmpty)
  }

  @Test func theNameAndTheIdReachTheSameFolder() async throws {
    let space = try makeSpace()
    let id = try await space.addMachine(name: "studio").id.rawValue
    let fs = await space.fs(.shared)

    let written = try await fs.write("/_/machines/studio/AGENTS.md", Data("manual".utf8), ifMatch: nil)
    #expect(try await text(fs, "/_/machines/\(id)/AGENTS.md") == "manual")
    #expect(try await text(fs, "/_/machines/STUDIO/AGENTS.md") == "manual")
    _ = try await fs.write("/_/machines/\(id)/AGENTS.md", Data("edited".utf8), ifMatch: written)
    #expect(try await text(fs, "/_/machines/studio/AGENTS.md") == "edited")
    #expect(try await fs.list("/_/machines/studio").1.map(\.name) == ["AGENTS.md"])
    #expect(try await fs.stat("/_/machines/studio").kind == .directory)
    #expect(try await space.history(path("/_/machines/studio/AGENTS.md"), in: .shared).count == 2)
  }

  @Test func theListingShowsOneEntryPerEnrolledMachineByName() async throws {
    let space = try makeSpace()
    let fs = await space.fs(.shared)
    _ = try await space.addMachine(name: "studio")
    _ = try await space.addMachine(name: "laptop")
    let bare = try await space.addMachine(name: nil).id.rawValue
    _ = try await fs.write("/_/machines/studio/AGENTS.md", Data("manual".utf8), ifMatch: nil)

    let (_, entries) = try await fs.list("/_/machines")
    #expect(entries.map(\.name) == [bare, "laptop", "studio"].sorted())
    #expect(entries.allSatisfy { $0.kind == .directory })
    #expect(try await fs.list("/_/machines/laptop").1.isEmpty)
    #expect(try await fs.stat("/_/machines/laptop").name == "laptop")
  }

  @Test func aPathUnderAnUnknownMachineIsRefusedForWritesAndNotFoundForReads() async throws {
    let space = try makeSpace()
    let fs = await space.fs(.shared)
    _ = try await space.addMachine(name: "studio")

    for ghost in ["/_/machines/ghost/AGENTS.md", "/_/machines/mc_zzzzzzzz/AGENTS.md"] {
      await #expect(throws: SpaceError.alreadyExists(ghost)) {
        try await fs.write(ghost, Data("x".utf8), ifMatch: nil)
      }
      await #expect(throws: SpaceError.notFound(ghost)) { try await fs.read(ghost) }
    }
    await #expect(throws: SpaceError.notFound("/_/machines/ghost")) { try await fs.list("/_/machines/ghost") }
    await #expect(throws: SpaceError.notFound("/_/machines/ghost")) { try await fs.stat("/_/machines/ghost") }
    await #expect(throws: SpaceError.self) {
      try await fs.write("/_/machines/studio", Data("x".utf8), ifMatch: nil)
    }
    await #expect(throws: SpaceError.self) {
      try await fs.move("/_/machines/studio", to: "/studio")
    }
  }

  @Test func aTableUnderAMachineTakesOnlyTheStoredPath() async throws {
    let space = try makeSpace()
    let id = try await space.addMachine(name: "studio").id.rawValue
    let header = TableHeader(columns: [TableColumn(name: "n", type: .integer)])

    await #expect(throws: SpaceError.alreadyExists("/_/machines/studio/t.table")) {
      try await space.createTable(path("/_/machines/studio/t.table"), header: header, in: .shared, acting: .shared)
    }
    await #expect(throws: SpaceError.alreadyExists("/_/machines/mc_zzzzzzzz/t.table")) {
      try await space.createTable(path("/_/machines/mc_zzzzzzzz/t.table"), header: header, in: .shared, acting: .shared)
    }
    _ = try await space.createTable(path("/_/machines/\(id)/t.table"), header: header, in: .shared, acting: .shared)
    #expect(try await space.fs(.shared).list("/_/machines/studio").1.map(\.name) == ["t.table"])
  }

  @Test func aTemplateInstantiatesIntoAMachineFolderByName() async throws {
    let space = try makeSpace()
    let id = try await space.addMachine(name: "studio").id.rawValue
    let fs = await space.fs(.shared)
    _ = try await fs.write(
      "/_/machines/studio/note.md",
      Data("---\ntemplate: {\"strategy\":\"incr\",\"prefix\":\"NOTE\",\"pad\":1}\n---\nhello\n".utf8),
      ifMatch: nil,
    )

    let created = try await space.instantiate(template: path("/_/machines/studio/note.md"), of: .shared, in: nil, of: .shared, acting: .shared)
    #expect(created.rawValue == "/_/machines/\(id)/NOTE-1.md")
    #expect(try await text(fs, "/_/machines/studio/NOTE-1.md").contains("hello"))
    await #expect(throws: SpaceError.alreadyExists("/_/machines/ghost")) {
      try await space.instantiate(template: path("/_/machines/studio/note.md"), of: .shared, in: path("/_/machines/ghost"), of: .shared, acting: .shared)
    }
  }

  @Test func aRenameMovesNothing() async throws {
    let space = try makeSpace()
    let fs = await space.fs(.shared)
    let studio = try await space.addMachine(name: "studio")
    _ = try await fs.write("/_/machines/studio/AGENTS.md", Data("manual".utf8), ifMatch: nil)
    let before = try await space.currentRevision()

    _ = try await space.renameMachine(studio.id, name: "atelier")
    #expect(try await space.currentRevision() == before)
    #expect(try await text(fs, "/_/machines/atelier/AGENTS.md") == "manual")
    #expect(try await fs.list("/_/machines").1.map(\.name) == ["atelier"])
    await #expect(throws: SpaceError.notFound("/_/machines/studio/AGENTS.md")) {
      try await fs.read("/_/machines/studio/AGENTS.md")
    }
  }

  @Test func aMoveMapsBothSidesAndHistoryUsesTheCurrentNames() async throws {
    let space = try makeSpace()
    let fs = await space.fs(.shared)
    let studio = try await space.addMachine(name: "studio")
    let laptop = try await space.addMachine(name: "laptop")
    _ = try await fs.write("/drafts/AGENTS.md", Data("manual".utf8), ifMatch: nil)

    try await fs.move("/drafts/AGENTS.md", to: "/_/machines/studio/AGENTS.md")
    let moved = try await space.currentRevision()
    try await fs.move("/_/machines/\(studio.id.rawValue)/AGENTS.md", to: "/_/machines/laptop/AGENTS.md")
    #expect(try await text(fs, "/_/machines/\(laptop.id.rawValue)/AGENTS.md") == "manual")
    await #expect(throws: SpaceError.notFound("/_/machines/\(studio.id.rawValue)/AGENTS.md")) {
      try await fs.read("/_/machines/studio/AGENTS.md")
    }

    _ = try await space.renameMachine(studio.id, name: "atelier")
    let then = await space.fs(.shared, at: Rev(moved))
    #expect(try await text(then, "/_/machines/atelier/AGENTS.md") == "manual")
    #expect(try await then.list("/_/machines/atelier").1.map(\.name) == ["AGENTS.md"])
    guard case let .move(to)? = try await space.history(path("/_/machines/atelier/AGENTS.md"), in: .shared).last?.2 else {
      throw MachineFoldersMismatch()
    }
    #expect(to == "/_/machines/\(laptop.id.rawValue)/AGENTS.md")

    _ = try await space.checkout(path("/_/machines/atelier/AGENTS.md"), rev: Rev(moved), in: .shared, acting: .shared)
    #expect(try await text(fs, "/_/machines/atelier/AGENTS.md") == "manual")
  }
}

private struct MachineFoldersMismatch: Error {}
