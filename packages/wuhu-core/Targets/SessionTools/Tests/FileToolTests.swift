import Dependencies
import Foundation
import JSONValue
import SessionDomain
@testable import SessionTools
import SpaceCore
import Testing
import struct WuhuAI.ToolArguments

@Suite struct FileGuardTests {
  @Test func writeWithoutReadOfExistingFileFailsTyped() async throws {
    try await withToolDeps { _ in
      let space = try Space.inMemory()
      _ = try await space.fs(.shared).write("/notes/a.md", Data("original".utf8), ifMatch: nil)
      var world = ToolWorld(executor: ToolExecutor(space: space), session: try await makeSession(space))

      let payload = try await world.run("write", .object(["path": "/notes/a.md", "content": "clobber"]))
      #expect(try failureMessage(payload).contains("read it at its current revision"))
      #expect(try await space.readTextForTest("/notes/a.md") == "original")
    }
  }

  @Test func createThenReadThenWriteThenStaleWrite() async throws {
    try await withToolDeps { _ in
      let space = try Space.inMemory()
      var world = ToolWorld(executor: ToolExecutor(space: space), session: try await makeSession(space))

      guard case .write = try await world.run("write", .object(["path": "/notes/new.md", "content": "v1"])) else {
        throw Mismatch("creation write should succeed without a prior read")
      }

      guard case let .read(read) = try await world.run("read", .object(["path": "/notes/new.md"])) else {
        throw Mismatch("read failed")
      }
      #expect(read.content == "v1")

      guard case let .write(written) = try await world.run("write", .object(["path": "/notes/new.md", "content": "v2"])) else {
        throw Mismatch("write after read should succeed")
      }
      guard case .journal = written.revision else { throw Mismatch("space write must log a journal revision") }

      // A foreign write moves the revision past our last read.
      _ = try await space.fs(.shared).write("/notes/new.md", Data("foreign".utf8), ifMatch: nil)
      let stale = try await world.run("write", .object(["path": "/notes/new.md", "content": "v3"]))
      #expect(try failureMessage(stale).contains("re-read"))
      #expect(try await space.readTextForTest("/notes/new.md") == "foreign")
    }
  }

  @Test func editRequiresAReadAndUniqueOldText() async throws {
    try await withToolDeps { _ in
      let space = try Space.inMemory()
      _ = try await space.fs(.shared).write("/a.txt", Data("one two one".utf8), ifMatch: nil)
      var world = ToolWorld(executor: ToolExecutor(space: space), session: try await makeSession(space))

      let unread = try await world.run("edit", .object([
        "path": "/a.txt", "edits": .array([.object(["old": "two", "new": "2"])]),
      ]))
      #expect(try failureMessage(unread).contains("read it before editing"))

      _ = try await world.run("read", .object(["path": "/a.txt"]))
      let ambiguous = try await world.run("edit", .object([
        "path": "/a.txt", "edits": .array([.object(["old": "one", "new": "1"])]),
      ]))
      #expect(try failureMessage(ambiguous).contains("matches 2 times"))

      guard case .edit = try await world.run("edit", .object([
        "path": "/a.txt", "edits": .array([.object(["old": "two", "new": "2"])]),
      ])) else { throw Mismatch("edit after read should succeed") }
      #expect(try await space.readTextForTest("/a.txt") == "one 2 one")
    }
  }

  @Test func machineFileGuardUsesMtime() async throws {
    try await withToolDeps { _ in
      let space = try Space.inMemory()
      let machineFS = FakeMachineFS()
      machineFS.put("/home/dev/notes.txt", "hello", mtime: 100)
      var world = ToolWorld(
        executor: ToolExecutor(space: space, machines: machineFS.seam),
        session: try await makeSession(space),
      )

      let path = JSONValue.string("machines://\(machineA.rawValue)/home/dev/notes.txt")
      guard case let .read(read) = try await world.run("read", .object(["path": path])) else {
        throw Mismatch("machine read failed")
      }
      #expect(read.path == "machines://\(machineA.rawValue)/home/dev/notes.txt")
      guard case .mtime = read.revision else { throw Mismatch("machine read must log an mtime revision") }

      guard case .write = try await world.run("write", .object(["path": path, "content": "updated"])) else {
        throw Mismatch("machine write after read should succeed")
      }

      machineFS.put("/home/dev/notes.txt", "foreign", mtime: 9999)
      let stale = try await world.run("write", .object(["path": path, "content": "late"]))
      #expect(try failureMessage(stale).contains("re-read"))
    }
  }
}

@Suite struct PathTests {
  @Test func aSessionThatNeverMountsReadsTheSpaceByAbsolutePath() async throws {
    try await withToolDeps { _ in
      let space = try Space.inMemory()
      _ = try await space.fs(.shared).write("/x.md", Data("hello".utf8), ifMatch: nil)
      var world = ToolWorld(executor: ToolExecutor(space: space), session: try await makeSession(space))

      guard case let .read(read) = try await world.run("read", .object(["path": "/x.md"])) else {
        throw Mismatch("absolute read failed")
      }
      #expect(read.path == "/x.md")
      #expect(read.content == "hello")
      #expect(world.delivered == nil)
    }
  }

  @Test func theSystemFilesReadAndSearchButRefuseWrites() async throws {
    try await withToolDeps { _ in
      let space = try Space.inMemory()
      var world = ToolWorld(executor: ToolExecutor(space: space), session: try await makeSession(space))

      guard case let .read(read) = try await world.run("read", .object(["path": "wuhu://system/AGENTS.md"])) else {
        throw Mismatch("system read failed")
      }
      #expect(read.path == "wuhu://system/AGENTS.md")
      #expect(read.content.hasPrefix("# Working in a Wuhu space"))
      #expect(world.delivered == nil, "the system files carry no context notice")

      guard case let .grep(grep) = try await world.run(
        "grep", .object(["pattern": "topLevel: true", "path": "wuhu://system/skills"]),
      ) else { throw Mismatch("system grep failed") }
      #expect(grep.output.contains("wuhu://system/skills/sessions/SKILL.md"))
      guard case let .find(find) = try await world.run("find", .object(["glob": "**/SKILL.md", "path": "wuhu://system/"])) else {
        throw Mismatch("system find failed")
      }
      #expect(find.output.contains("wuhu://system/skills/read-box/SKILL.md"))

      for (tool, arguments) in [
        ("write", ToolArguments.object(["path": "wuhu://system/AGENTS.md", "content": "y"])),
        ("edit", .object(["path": "wuhu://system/AGENTS.md", "edits": .array([.object(["old": "Wuhu", "new": "x"])])])),
      ] {
        let message = try failureMessage(try await world.run(tool, arguments))
        #expect(message.contains("wuhu://system/AGENTS.md is read-only"), "\(tool): \(message)")
      }
      #expect(try await space.fs(.shared).list("/").1.isEmpty, "nothing of the system lands in the space")
    }
  }

  @Test func aRelativePathNamesBothAddressForms() async throws {
    try await withToolDeps { _ in
      let space = try Space.inMemory()
      _ = try await space.fs(.shared).write("/x.md", Data("hello".utf8), ifMatch: nil)
      var world = ToolWorld(executor: ToolExecutor(space: space), session: try await makeSession(space))

      let calls: [(String, ToolArguments)] = [
        ("read", .object(["path": "x.md"])),
        ("write", .object(["path": "x.md", "content": "y"])),
        ("edit", .object(["path": "x.md", "edits": .array([.object(["old": "hello", "new": "bye"])])])),
        ("grep", .object(["pattern": "hello", "path": "notes"])),
        ("find", .object(["glob": "*.md", "path": "notes"])),
      ]
      for (tool, arguments) in calls {
        let refused = try await world.run(tool, arguments)
        let message = try failureMessage(refused)
        #expect(message.contains("relative path"), "\(tool)")
        #expect(message.contains("machines://"), "\(tool)")
      }
      let wuhuHost = try await world.run("read", .object(["path": "wuhu://example.test/x.md"]))
      #expect(try failureMessage(wuhuHost) == "not a file address: wuhu://example.test/x.md; use /<path> for this group, wuhu://<group>.localspace/<path> for another group, machines://<machine>/<path> for a machine or wuhu://system/<path> for the system files")
    }
  }

  @Test func escapingTheRootFailsTyped() async throws {
    try await withToolDeps { _ in
      let space = try Space.inMemory()
      var world = ToolWorld(executor: ToolExecutor(space: space), session: try await makeSession(space))
      let escaped = try await world.run("read", .object(["path": "/../../etc/passwd"]))
      #expect(try failureMessage(escaped).contains("escapes the root"))
    }
  }

  @Test func unknownToolFailsTyped() async throws {
    try await withToolDeps { _ in
      let space = try Space.inMemory()
      var world = ToolWorld(executor: ToolExecutor(space: space), session: try await makeSession(space))
      let unknown = try await world.run("teleport", .object([:]))
      #expect(try failureMessage(unknown).contains("unknown tool"))
    }
  }
}

extension Space {
  func readTextForTest(_ path: String) async throws -> String {
    let (_, data) = try await fs(.shared).read(path)
    return String(decoding: data, as: UTF8.self)
  }
}
