import Foundation
import JSONValue
import SpaceContract
import SpaceTools
import Testing

@Suite struct SearchToolTests {
  private func seedCorpus(_ context: SpaceToolContext) async throws {
    _ = try await seedFile("/docs/a.txt", "foo one\nplain\nfoo two", context)
    _ = try await seedFile("/docs/b.txt", "nothing here", context)
    _ = try await seedFile("/docs/c.txt", "foo three", context)
    _ = try await seedFile("/readme.md", "foo four", context)
  }

  @Test func grepFindsMatchesAcrossFiles() async throws {
    let context = try makeContext()
    try await seedCorpus(context)
    let output = try await run("grep", .object(["pattern": "foo \\w+"]), context, as: GrepOutput.self)
    #expect(output.cursor == nil)
    #expect(output.matches.map(\.path) == ["/docs/a.txt", "/docs/a.txt", "/docs/c.txt", "/readme.md"])
    #expect(output.matches.map(\.line) == [1, 3, 1, 1])
    #expect(output.matches[1].text == "foo two")
  }

  @Test func grepScopedToPath() async throws {
    let context = try makeContext()
    try await seedCorpus(context)
    let output = try await run("grep", .object(["pattern": "foo", "path": "/docs"]), context, as: GrepOutput.self)
    #expect(output.matches.map(\.path) == ["/docs/a.txt", "/docs/a.txt", "/docs/c.txt"])
  }

  @Test func grepCursorContinuesToCompletion() async throws {
    let context = try makeContext()
    try await seedCorpus(context)
    let full = try await run("grep", .object(["pattern": "foo"]), context, as: GrepOutput.self)

    var collected: [Match] = []
    var step: String?
    for _ in 0 ..< 10 {
      var input: JSONValue = .object(["pattern": "foo", "matchLimit": 1])
      if let step { input = .object(["pattern": "foo", "matchLimit": 1, "step": .string(step)]) }
      let page = try await run("grep", input, context, as: GrepOutput.self)
      collected += page.matches
      guard let next = page.cursor else { break }
      step = next
    }
    #expect(collected == full.matches)
  }

  @Test func grepHonorsEntryLimitCursor() async throws {
    let context = try makeContext()
    try await seedCorpus(context)
    let page = try await run("grep", .object(["pattern": "foo", "entryLimit": 1]), context, as: GrepOutput.self)
    #expect(page.matches.map(\.path) == ["/docs/a.txt", "/docs/a.txt"])
    let cursor = try #require(page.cursor)

    let rest = try await run(
      "grep", .object(["pattern": "foo", "step": .string(cursor)]), context, as: GrepOutput.self,
    )
    #expect(rest.cursor == nil)
    #expect(rest.matches.map(\.path) == ["/docs/c.txt", "/readme.md"])
  }

  @Test func grepRejectsInvalidPattern() async throws {
    let context = try makeContext()
    let bad = await failure("grep", .object(["pattern": "("]), context)
    #expect({ if case .failed(code: .invalidArgument, _, _, _) = bad { true } else { false } }())
  }

  @Test func grepRejectsNonPositiveLimits() async throws {
    let context = try makeContext()
    for input in [
      JSONValue.object(["pattern": "x", "matchLimit": 0]),
      .object(["pattern": "x", "matchLimit": -3]),
      .object(["pattern": "x", "entryLimit": 0]),
      .object(["pattern": "x", "entryLimit": -1]),
    ] {
      let bad = await failure("grep", input, context)
      #expect({ if case .failed(code: .invalidArgument, _, _, _) = bad { true } else { false } }(), "\(input)")
    }
  }

  @Test func grepMatchAndEntryLimitsInteract() async throws {
    let context = try makeContext()
    try await seedCorpus(context)
    let full = try await run("grep", .object(["pattern": "foo"]), context, as: GrepOutput.self)

    var collected: [Match] = []
    var step: String?
    for _ in 0 ..< 20 {
      var input: JSONValue = .object(["pattern": "foo", "matchLimit": 1, "entryLimit": 1])
      if let step {
        input = .object(["pattern": "foo", "matchLimit": 1, "entryLimit": 1, "step": .string(step)])
      }
      let page = try await run("grep", input, context, as: GrepOutput.self)
      #expect(page.matches.count <= 1)
      collected += page.matches
      guard let next = page.cursor else { break }
      step = next
    }
    #expect(collected == full.matches)
  }

  @Test func findMatchesGlob() async throws {
    let context = try makeContext()
    try await seedCorpus(context)
    let txt = try await run("find", .object(["glob": "/docs/*.txt"]), context, as: FindOutput.self)
    #expect(txt.paths == ["/docs/a.txt", "/docs/b.txt", "/docs/c.txt"])

    let all = try await run("find", .object(["glob": "**/*.md", "path": "/"]), context, as: FindOutput.self)
    #expect(all.paths == ["/readme.md"])
  }

  @Test func findSeesTableNodes() async throws {
    let context = try makeContext()
    try await seedCorpus(context)
    _ = try await run(
      "table.create",
      .object(["path": "/docs/t.table", "header": .object(["columns": .array([.object(["name": "n", "type": "integer"])])])]),
      context,
      as: RevisionOutput.self,
    )
    let tables = try await run("find", .object(["glob": "/**/*.table"]), context, as: FindOutput.self)
    #expect(tables.paths == ["/docs/t.table"])

    let everything = try await run("find", .object(["glob": "/**"]), context, as: FindOutput.self)
    #expect(everything.paths == ["/docs/a.txt", "/docs/b.txt", "/docs/c.txt", "/docs/t.table", "/readme.md"])

    let scoped = try await run("find", .object(["glob": "/**", "path": "/docs"]), context, as: FindOutput.self)
    #expect(scoped.paths == ["/docs/a.txt", "/docs/b.txt", "/docs/c.txt", "/docs/t.table"])

    let grep = try await run("grep", .object(["pattern": "."]), context, as: GrepOutput.self)
    #expect(!grep.matches.map(\.path).contains("/docs/t.table"))
  }

  @Test func findHonorsMatchLimitCursor() async throws {
    let context = try makeContext()
    try await seedCorpus(context)
    let full = try await run("find", .object(["glob": "/**"]), context, as: FindOutput.self)
    #expect(full.cursor == nil)

    var collected: [String] = []
    var step: String?
    for _ in 0 ..< 10 {
      var input: JSONValue = .object(["glob": "/**", "matchLimit": 1])
      if let step { input = .object(["glob": "/**", "matchLimit": 1, "step": .string(step)]) }
      let page = try await run("find", input, context, as: FindOutput.self)
      #expect(page.paths.count <= 1)
      collected += page.paths
      guard let next = page.cursor else { break }
      step = next
    }
    #expect(collected == full.paths)
  }

  @Test func findHonorsEntryLimitCursor() async throws {
    let context = try makeContext()
    try await seedCorpus(context)
    let page = try await run("find", .object(["glob": "/docs/*.txt", "entryLimit": 2]), context, as: FindOutput.self)
    #expect(page.paths == ["/docs/a.txt", "/docs/b.txt"])
    let cursor = try #require(page.cursor)
    #expect(cursor == "/docs/c.txt")

    let rest = try await run(
      "find", .object(["glob": "/docs/*.txt", "entryLimit": 2, "step": .string(cursor)]), context, as: FindOutput.self,
    )
    #expect(rest.paths == ["/docs/c.txt"])
    #expect(rest.cursor == nil)
  }

  @Test func findRejectsNonPositiveLimits() async throws {
    let context = try makeContext()
    for input in [
      JSONValue.object(["glob": "/**", "matchLimit": 0]),
      .object(["glob": "/**", "entryLimit": -1]),
    ] {
      let bad = await failure("find", input, context)
      #expect({ if case .failed(code: .invalidArgument, _, _, _) = bad { true } else { false } }(), "\(input)")
    }
  }
}
