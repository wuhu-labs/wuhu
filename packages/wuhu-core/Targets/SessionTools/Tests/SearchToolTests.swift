import Foundation
import JSONValue
import SessionDomain
@testable import SessionTools
import SpaceCore
import Testing

@Suite struct SearchToolTests {
  @Test func findHonorsMatchLimitAndResumesWithStep() async throws {
    try await withToolDeps { _ in
      let space = try Space.inMemory()
      for name in ["a", "b", "c", "d", "e"] {
        _ = try await space.fs(.shared).write("/src/\(name).swift", Data("x".utf8), ifMatch: nil)
      }
      var world = ToolWorld(executor: ToolExecutor(space: space), session: try await makeSession(space))

      guard case let .find(first) = try await world.run(
        "find", .object(["glob": "**/*.swift", "path": "/src", "match_limit": 2]),
      ) else { throw Mismatch("find failed") }
      let lines = first.output.split(separator: "\n").map(String.init)
      #expect(lines.prefix(2) == ["/src/a.swift", "/src/b.swift"])
      let stepLine = try #require(lines.last { $0.contains("step:") })
      let step = stepLine.split(separator: "\"")[1]

      guard case let .find(second) = try await world.run(
        "find", .object(["glob": "**/*.swift", "path": "/src", "match_limit": 2, "step": .string(String(step))]),
      ) else { throw Mismatch("stepped find failed") }
      #expect(second.output.contains("/src/c.swift"))
      #expect(second.output.contains("/src/d.swift"))
      #expect(!second.output.contains("/src/b.swift"))
    }
  }

  @Test func findSaysWhatItSkippedAndIncludesItOnRequest() async throws {
    try await withToolDeps { _ in
      let space = try Space.inMemory()
      _ = try await space.fs(.shared).write("/src/.gitignore", Data("gen/\n".utf8), ifMatch: nil)
      _ = try await space.fs(.shared).write("/src/a.txt", Data("x".utf8), ifMatch: nil)
      _ = try await space.fs(.shared).write("/src/gen/b.txt", Data("x".utf8), ifMatch: nil)
      var world = ToolWorld(executor: ToolExecutor(space: space), session: try await makeSession(space))

      guard case let .find(plain) = try await world.run(
        "find", .object(["glob": "**/*.txt", "path": "/src"]),
      ) else { throw Mismatch("find failed") }
      #expect(plain.output == "/src/a.txt\nskipped 1 hidden (pass hidden: true to include), e.g. /src/.gitignore\nskipped 1 ignored by .gitignore (pass no_ignore: true to include), e.g. /src/gen")

      guard case let .find(all) = try await world.run(
        "find", .object(["glob": "**/*.txt", "path": "/src", "no_ignore": true]),
      ) else { throw Mismatch("find failed") }
      #expect(all.output == "/src/a.txt\n/src/gen/b.txt\nskipped 1 hidden (pass hidden: true to include), e.g. /src/.gitignore")

      let bad = try await world.run("find", .object(["glob": "*", "match_limit": 0]))
      #expect(try failureMessage(bad).contains("positive"))
    }
  }

  @Test func grepMatchesUnderTheGivenPath() async throws {
    try await withToolDeps { _ in
      let space = try Space.inMemory()
      _ = try await space.fs(.shared).write("/src/a.swift", Data("let alpha = 1\nlet beta = 2".utf8), ifMatch: nil)
      _ = try await space.fs(.shared).write("/src/b.swift", Data("let beta = 3".utf8), ifMatch: nil)
      _ = try await space.fs(.shared).write("/elsewhere/c.swift", Data("let beta = 4".utf8), ifMatch: nil)
      var world = ToolWorld(executor: ToolExecutor(space: space), session: try await makeSession(space))

      guard case let .grep(result) = try await world.run("grep", .object(["pattern": "beta", "path": "/src"])) else {
        throw Mismatch("grep failed")
      }
      #expect(result.output.contains("/src/a.swift:2: let beta = 2"))
      #expect(result.output.contains("/src/b.swift:1: let beta = 3"))
      #expect(!result.output.contains("alpha"))
      #expect(!result.output.contains("/elsewhere"))
    }
  }

  @Test func queryRunsThroughTheSandbox() async throws {
    try await withToolDeps { _ in
      let space = try Space.inMemory()
      let session = try await makeSession(space)
      var world = ToolWorld(executor: ToolExecutor(space: space), session: session)

      guard case let .query(rows) = try await world.run(
        "query", .object(["sql": "SELECT id, title FROM sessions ORDER BY id"]),
      ) else { throw Mismatch("query failed") }
      #expect(rows.output.contains(session.rawValue))
      #expect(rows.output.contains("test"))

      let mutation = try await world.run("query", .object(["sql": "DELETE FROM sessions"]))
      _ = try failureMessage(mutation)
    }
  }

  @Test func queryStopsReadingPastTheScriptBuffer() async throws {
    try await withToolDeps { _ in
      let space = try Space.inMemory()
      var world = ToolWorld(executor: ToolExecutor(space: space), session: try await makeSession(space))

      let huge = try await world.run("query", .object([
        "sql": "SELECT zeroblob(68000000)",
      ]))
      let message = try failureMessage(huge)
      #expect(message.contains("the result is over 64 MiB"), "\(message)")
    }
  }
}
