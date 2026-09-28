import Foundation
import JSONValue
import SessionDomain
@testable import SessionTools
import SpaceCore
import Testing

private let skillMarkdown = """
---
name: lint
description: Run the linter before committing.
---

# Lint

Body that must never be inlined into the context.
"""

private func repoMachine() -> FakeMachineFS {
  let machineFS = FakeMachineFS()
  machineFS.put("/work/AGENTS.md", "above the repo", mtime: 1)
  machineFS.put("/work/repo/.git/HEAD", "ref: refs/heads/main", mtime: 1)
  machineFS.put("/work/repo/AGENTS.md", "repo manual", mtime: 1)
  machineFS.put("/work/repo/.agents/skills/lint/SKILL.md", skillMarkdown, mtime: 1)
  machineFS.put("/work/repo/.agents/skills/bare/SKILL.md", "no frontmatter here", mtime: 1)
  machineFS.put("/work/repo/README.md", "readme", mtime: 1)
  machineFS.put("/work/repo/pkg/AGENTS.md", "package manual", mtime: 1)
  machineFS.put("/work/repo/pkg/main.swift", "code", mtime: 1)
  machineFS.put("/work/loose/AGENTS.md", "not in a repo", mtime: 1)
  machineFS.put("/work/loose/a.txt", "loose", mtime: 1)
  return machineFS
}

private func machinePath(_ path: String) -> JSONValue {
  .string("machines://\(machineA.rawValue)\(path)")
}

private func readContext(_ world: inout ToolWorld, _ path: String) async throws -> ScopeContext? {
  guard case .read = try await world.run("read", .object(["path": machinePath(path)])) else {
    throw Mismatch("read \(path) failed")
  }
  return world.delivered
}

private func rendered(_ path: String) -> String {
  "machines://\(machineA.rawValue)\(path)"
}

@Suite struct ContextTests {
  @Test func theFirstTouchDeliversTheRepositoryFromItsRootDownOnce() async throws {
    try await withToolDeps { _ in
      let space = try Space.inMemory()
      var world = ToolWorld(
        executor: ToolExecutor(space: space, machines: repoMachine().seam),
        session: try await makeSession(space),
      )

      let context = try #require(try await readContext(&world, "/work/repo/pkg/main.swift"))
      let root = "machines://\(machineA.rawValue)/work/repo"
      #expect(context.folders == [root: root, root + "/pkg": root])
      #expect(context.text.contains("<AGENTS.md from=\"\(root)/AGENTS.md\">\nrepo manual\n</AGENTS.md>"))
      #expect(context.text.contains("<AGENTS.md from=\"\(root)/pkg/AGENTS.md\">\npackage manual\n</AGENTS.md>"))
      #expect(context.text.contains("- lint — Run the linter before committing. (\(root)/.agents/skills/lint/SKILL.md)"))
      #expect(context.text.contains("- bare (\(root)/.agents/skills/bare/SKILL.md)"))
      #expect(!context.text.contains("Body that must never be inlined"))
      #expect(!context.text.contains("above the repo"))

      #expect(try await readContext(&world, "/work/repo/pkg/main.swift") == nil)
      #expect(try await readContext(&world, "/work/repo/README.md") == nil)
    }
  }

  @Test func descendingLaterDeliversOnlyTheNewFolders() async throws {
    try await withToolDeps { _ in
      let space = try Space.inMemory()
      var world = ToolWorld(
        executor: ToolExecutor(space: space, machines: repoMachine().seam),
        session: try await makeSession(space),
      )

      let top = try #require(try await readContext(&world, "/work/repo/README.md"))
      #expect(top.text.contains("repo manual"))
      #expect(!top.text.contains("package manual"))

      let nested = try #require(try await readContext(&world, "/work/repo/pkg/main.swift"))
      #expect(nested.text.contains("package manual"))
      #expect(!nested.text.contains("repo manual"))
    }
  }

  @Test func aFolderInNoRepositoryIsRecordedWithoutText() async throws {
    try await withToolDeps { _ in
      let space = try Space.inMemory()
      var world = ToolWorld(
        executor: ToolExecutor(space: space, machines: repoMachine().seam),
        session: try await makeSession(space),
      )

      let context = try #require(try await readContext(&world, "/work/loose/a.txt"))
      let expected: [String: String?] = [rendered("/"): nil, rendered("/work"): nil, rendered("/work/loose"): nil]
      #expect(context.folders == expected)
      #expect(context.text.isEmpty)
    }
  }

  @Test func aNonRepositoryFolderTouchedAgainCostsNoStats() async throws {
    try await withToolDeps { _ in
      let space = try Space.inMemory()
      let machineFS = repoMachine()
      var world = ToolWorld(
        executor: ToolExecutor(space: space, machines: machineFS.seam),
        session: try await makeSession(space),
      )

      #expect(try await readContext(&world, "/work/loose/a.txt") != nil)
      let before = machineFS.stats.withLock { $0 }
      #expect(try await readContext(&world, "/work/loose/a.txt") == nil)
      #expect(machineFS.stats.withLock { $0 } == before)
    }
  }

  @Test func aSiblingUnderARecordedRepositoryDeliversOnlyItselfWithoutStats() async throws {
    try await withToolDeps { _ in
      let space = try Space.inMemory()
      let machineFS = FakeMachineFS()
      machineFS.put("/a/.git/HEAD", "ref: refs/heads/main", mtime: 1)
      machineFS.put("/a/AGENTS.md", "a manual", mtime: 1)
      machineFS.put("/a/b/AGENTS.md", "b manual", mtime: 1)
      machineFS.put("/a/b/x/f", "x", mtime: 1)
      machineFS.put("/a/b/z/AGENTS.md", "z manual", mtime: 1)
      machineFS.put("/a/b/z/f", "z", mtime: 1)
      var world = ToolWorld(
        executor: ToolExecutor(space: space, machines: machineFS.seam),
        session: try await makeSession(space),
      )

      let first = try #require(try await readContext(&world, "/a/b/x/f"))
      #expect(Set(first.folders.keys) == [rendered("/a"), rendered("/a/b"), rendered("/a/b/x")])
      let before = machineFS.stats.withLock { $0 }
      let second = try #require(try await readContext(&world, "/a/b/z/f"))
      #expect(second.folders == [rendered("/a/b/z"): rendered("/a")])
      #expect(second.text.contains("z manual"))
      #expect(!second.text.contains("a manual"))
      #expect(!second.text.contains("b manual"))
      #expect(machineFS.stats.withLock { $0 } == before)
    }
  }

  @Test func aRepositoryNestedInARecordedNonRepositoryFolderIsFound() async throws {
    try await withToolDeps { _ in
      let space = try Space.inMemory()
      var world = ToolWorld(
        executor: ToolExecutor(space: space, machines: repoMachine().seam),
        session: try await makeSession(space),
      )

      #expect(try await readContext(&world, "/work/loose/a.txt")?.text.isEmpty == true)
      let context = try #require(try await readContext(&world, "/work/repo/pkg/main.swift"))
      let root = rendered("/work/repo")
      #expect(context.folders == [root: root, root + "/pkg": root])
      #expect(context.text.contains("repo manual"))
      #expect(context.text.contains("package manual"))
      #expect(!context.text.contains("above the repo"))
    }
  }

  @Test func touchingAParentOfARecordedFolderDeliversNothing() async throws {
    try await withToolDeps { _ in
      let space = try Space.inMemory()
      var world = ToolWorld(
        executor: ToolExecutor(space: space, machines: repoMachine().seam),
        session: try await makeSession(space),
      )

      #expect(try await readContext(&world, "/work/repo/pkg/main.swift") != nil)
      #expect(try await readContext(&world, "/work/repo/README.md") == nil)
    }
  }

  @Test func spacePathsLeaveInstructionsToTheSystemPrompt() async throws {
    try await withToolDeps { _ in
      let space = try Space.inMemory()
      _ = try await space.fs(.shared).write("/AGENTS.md", Data("space manual".utf8), ifMatch: nil)
      _ = try await space.fs(.shared).write("/docs/a.md", Data("x".utf8), ifMatch: nil)
      var world = ToolWorld(executor: ToolExecutor(space: space), session: try await makeSession(space))

      guard case .read = try await world.run("read", .object(["path": "/docs/a.md"])) else {
        throw Mismatch("space read failed")
      }
      #expect(world.delivered == nil)
    }
  }

  @Test func aCompactionDeliversTheRepositoryAgainOnTheNextTouch() async throws {
    try await withToolDeps { _ in
      let space = try Space.inMemory()
      var world = ToolWorld(
        executor: ToolExecutor(space: space, machines: repoMachine().seam),
        session: try await makeSession(space),
      )

      #expect(try await readContext(&world, "/work/repo/README.md") != nil)
      #expect(try await readContext(&world, "/work/repo/README.md") == nil)

      world.state = ToolExecutionState(resuming: StateSnapshot(carrying: world.state, preReads: []))
      let again = try #require(try await readContext(&world, "/work/repo/README.md"))
      #expect(again.text.contains("repo manual"))
    }
  }

  @Test func theToolResultHoldsOnlyTheToolOutput() async throws {
    try await withToolDeps { _ in
      let space = try Space.inMemory()
      var world = ToolWorld(
        executor: ToolExecutor(space: space, machines: repoMachine().seam),
        session: try await makeSession(space),
      )

      let rendered = try await world.run("read", .object(["path": machinePath("/work/repo/pkg/main.swift")])).renderedText
      #expect(rendered.contains("code"))
      #expect(!rendered.contains("package manual"))
      #expect(world.delivered?.text.contains("package manual") == true)
    }
  }

  @Test func enormousAgentsFilesAreCapped() async throws {
    try await withToolDeps { _ in
      let space = try Space.inMemory()
      let machineFS = repoMachine()
      machineFS.put("/work/repo/AGENTS.md", String(repeating: "a", count: 40 * 1024), mtime: 2)
      var world = ToolWorld(
        executor: ToolExecutor(space: space, machines: machineFS.seam),
        session: try await makeSession(space),
      )

      let context = try #require(try await readContext(&world, "/work/repo/README.md"))
      #expect(context.text.contains("(AGENTS.md truncated at 32KiB)"))
      #expect(context.text.utf8.count < 34 * 1024)
    }
  }
}
