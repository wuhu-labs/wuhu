import ControlledTime
import Dependencies
import DeterministicDependencies
@testable import FileSearch
import Foundation
import JSONValue
import SpaceContract
import enum SpaceCore.SpaceError
import SpaceFS
@testable import SpaceTools
import Synchronization
import Testing

@Suite(.deterministicDependencies(clock: VirtualClock())) struct SearchToolTests {
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
    ] {
      let bad = await failure("grep", input, context)
      #expect({ if case .failed(code: .invalidArgument, _, _, _) = bad { true } else { false } }(), "\(input)")
    }
  }

  @Test func findMatchesGlob() async throws {
    let context = try makeContext()
    try await seedCorpus(context)
    let txt = try await run("find", .object(["glob": "/docs/*.txt"]), context, as: FindOutput.self)
    #expect(txt.paths == ["/docs/a.txt", "/docs/b.txt", "/docs/c.txt"])
    #expect(txt.scanned == 5, "docs, its three files and readme.md")

    let all = try await run("find", .object(["glob": "**/*.md", "path": "/"]), context, as: FindOutput.self)
    #expect(all.paths == ["/readme.md"])
    // The glob is relative to `path`: a name without a slash matches at any depth.
    let named = try await run("find", .object(["glob": "c.txt"]), context, as: FindOutput.self)
    #expect(named.paths == ["/docs/c.txt"])
    let anchored = try await run("find", .object(["glob": "/*.txt", "path": "/docs"]), context, as: FindOutput.self)
    #expect(anchored.paths == ["/docs/a.txt", "/docs/b.txt", "/docs/c.txt"])
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

  @Test func findRejectsNonPositiveLimits() async throws {
    let context = try makeContext()
    for input in [
      JSONValue.object(["glob": "/**", "matchLimit": 0]),
      .object(["glob": "/**", "matchLimit": -1]),
    ] {
      let bad = await failure("find", input, context)
      #expect({ if case .failed(code: .invalidArgument, _, _, _) = bad { true } else { false } }(), "\(input)")
    }
  }

  @Test func stepsAreBoundToTheirSearchAndMalformedOnesAreRefused() async throws {
    let context = try makeContext()
    try await seedCorpus(context)
    let find = try await run("find", .object(["glob": "/**", "matchLimit": 1]), context, as: FindOutput.self)
    let findStep = try #require(find.cursor)
    let grep = try await run("grep", .object(["pattern": "foo", "matchLimit": 1]), context, as: GrepOutput.self)
    let grepStep = try #require(grep.cursor)
    for input in [
      JSONValue.object(["glob": "/**", "step": "/docs/b.txt"]),
      .object(["glob": "/**", "step": "s2.!!"]),
      .object(["glob": "/**", "step": "s2."]),
      .object(["glob": "/**/*.txt", "step": .string(findStep)]),
      .object(["glob": "/**", "path": "/docs", "step": .string(findStep)]),
      .object(["glob": "/**", "step": .string(grepStep)]),
    ] {
      let bad = await failure("find", input, context)
      #expect({ if case .failed(code: .invalidArgument, _, _, _) = bad { true } else { false } }(), "\(input)")
    }
    for input in [
      JSONValue.object(["pattern": "foo", "step": "1@/docs/a.txt"]),
      .object(["pattern": "foo", "step": "1@"]),
      .object(["pattern": "fo+", "step": .string(grepStep)]),
      .object(["pattern": "foo", "step": .string(findStep)]),
    ] {
      let bad = await failure("grep", input, context)
      #expect({ if case .failed(code: .invalidArgument, _, _, _) = bad { true } else { false } }(), "\(input)")
    }
  }

  @Test func largeLimitsAreCappedNotRefused() async throws {
    let context = try makeContext()
    _ = try await seedFile("/m", String(repeating: "x\n", count: SearchLimits.maxLimit + 5), context)
    let page = try await run("grep", .object(["pattern": "x", "matchLimit": 50000]), context, as: GrepOutput.self)
    #expect(page.matches.count > SearchLimits.defaultLimit && page.matches.count <= SearchLimits.maxLimit)
    var lines = page.matches.map(\.line)
    var step = page.cursor
    while let next = step {
      let rest = try await run("grep", .object(["pattern": "x", "matchLimit": 50000, "step": .string(next)]), context, as: GrepOutput.self)
      lines += rest.matches.map(\.line)
      step = rest.cursor
    }
    #expect(lines == Array(1 ... SearchLimits.maxLimit + 5))
  }

  @Test func longLinesAreClamped() async throws {
    let context = try makeContext()
    _ = try await seedFile("/a/long.txt", "foo" + String(repeating: "é", count: 2000), context)
    let output = try await run("grep", .object(["pattern": "foo"]), context, as: GrepOutput.self)
    let text = try #require(output.matches.first?.text)
    #expect(output.matches.map(\.path) == ["/a/long.txt"])
    #expect(text.hasPrefix("foo") && text.contains("[line clamped: 4003 bytes]"))
    #expect(text.utf8.count < 600)
    #expect(output.skipped.isEmpty)
  }

  // `/users` (and `/_`) at a space's root are passed over, as `ls` hides them, unless asked.
  @Test func hiddenRootEntriesAreSkippedUnlessAsked() async throws {
    let context = try makeContext()
    _ = try await seedFile("/users/me.md", "needle", context)
    _ = try await seedFile("/notes/n.md", "needle", context)
    let plain = try await run("grep", .object(["pattern": "needle"]), context, as: GrepOutput.self)
    #expect(plain.matches.map(\.path) == ["/notes/n.md"])
    #expect(plain.skipped == [SearchSkipped(reason: .hidden, count: 1, example: "/users")])
    let all = try await run("grep", .object(["pattern": "needle", "hidden": true]), context, as: GrepOutput.self)
    #expect(all.matches.map(\.path) == ["/notes/n.md", "/users/me.md"])
    let inside = try await run("find", .object(["glob": "*.md", "path": "/users"]), context, as: FindOutput.self)
    #expect(inside.paths == ["/users/me.md"], "a hidden root is searched when named")
  }

  @Test func gitignoreIsHonoredUnlessNoIgnore() async throws {
    let context = try makeContext()
    _ = try await seedFile("/proj/.gitignore", "*.log\nbuild/\n", context)
    _ = try await seedFile("/proj/a.log", "x", context)
    _ = try await seedFile("/proj/build/out.txt", "x", context)
    _ = try await seedFile("/proj/src/main.txt", "x", context)
    let plain = try await run("find", .object(["glob": "*.txt", "path": "/proj"]), context, as: FindOutput.self)
    #expect(plain.paths == ["/proj/src/main.txt"])
    #expect(plain.skipped == [
      SearchSkipped(reason: .hidden, count: 1, example: "/proj/.gitignore"), SearchSkipped(reason: .ignored, count: 2, example: "/proj/a.log"),
    ])
    let all = try await run("find", .object(["glob": "**", "path": "/proj", "noIgnore": true, "hidden": true]), context, as: FindOutput.self)
    #expect(all.paths == ["/proj/.gitignore", "/proj/a.log", "/proj/build/out.txt", "/proj/src/main.txt"])
  }

  // A file is read a range at a time, whatever its size: a match past one
  // page's read budget is found on a later page, as it is on a machine.
  @Test func aFileLargerThanAPageReadIsGreppedToItsEnd() async throws {
    let context = try makeContext()
    let readBudget = 4 * SearchLimits.lineBytes
    let filler = String(repeating: "padding line\n", count: (readBudget + SearchLimits.lineBytes) / 13)
    _ = try await seedFile("/big.txt", filler + "needle", context)
    let target = try await context.resolve("/")
    let source = SpaceSearchSource(backend: target.backend, hidesRootEntries: target.isSpace)
    var query = SearchQuery(mode: .grep, pattern: "needle", root: target.path, scope: "space")
    var found: [Int] = []
    var pages = 0
    repeat {
      let page = try await query.run(in: source, clock: VirtualClock(), readBudget: readBudget)
      #expect(page.skipped.isEmpty)
      found += page.hits.compactMap(\.line)
      query.step = page.cursor
      pages += 1
    } while query.step != nil && pages < 10
    #expect(found == [filler.utf8.count / 13 + 1])
    #expect(pages == 2)
  }

  // Dot-names are hidden in a space as they are on a machine's disk.
  @Test func dotNamesAreHiddenUnlessAsked() async throws {
    let context = try makeContext()
    _ = try await seedFile("/proj/.env", "needle", context)
    _ = try await seedFile("/proj/.cache/x.txt", "needle", context)
    _ = try await seedFile("/proj/a.txt", "needle", context)
    let plain = try await run("grep", .object(["pattern": "needle", "path": "/proj"]), context, as: GrepOutput.self)
    #expect(plain.matches.map(\.path) == ["/proj/a.txt"])
    #expect(plain.skipped == [SearchSkipped(reason: .hidden, count: 2, example: "/proj/.cache")])
    let all = try await run("grep", .object(["pattern": "needle", "path": "/proj", "hidden": true]), context, as: GrepOutput.self)
    #expect(all.matches.map(\.path) == ["/proj/.cache/x.txt", "/proj/.env", "/proj/a.txt"])
  }

  // A cursor continues only on the backend that made it: the same root on
  // another backend refuses it.
  @Test func aCursorIsRefusedOnAnotherBackend() async throws {
    let context = try makeContext()
    _ = try await seedFile("/a.txt", "x", context)
    _ = try await seedFile("/b.txt", "x", context)
    let first = try await run("find", .object(["glob": "*", "matchLimit": 1]), context, as: FindOutput.self)
    let step = try #require(first.cursor)
    let elsewhere = await failure("find", .object(["glob": "*", "path": "wuhu://system/", "step": .string(step)]), context)
    #expect({ if case .failed(code: .invalidArgument, _, _, _) = elsewhere { true } else { false } }())
    let here = try await run("find", .object(["glob": "*", "step": .string(step)]), context, as: FindOutput.self)
    #expect(here.paths == ["/b.txt"])
  }

  // Pages end on counts only, so a loaded server pages exactly like an idle one.
  @Test func pagesEndOnCountsNeverOnTime() async throws {
    let context = try makeContext()
    _ = try await seedFile("/a.txt", "foo 1\nbar\nfoo 2", context)
    _ = try await seedFile("/b.txt", "foo 3", context)
    var found: [String] = []
    var step: String?
    var pages = 0
    repeat {
      let input: JSONValue = step.map { .object(["pattern": "foo", "matchLimit": 1, "step": .string($0)]) } ?? .object(["pattern": "foo", "matchLimit": 1])
      let page = try await run("grep", input, context, as: GrepOutput.self)
      #expect(page.matches.count == 1)
      found += page.matches.map { "\($0.path):\($0.line)" }
      step = page.cursor
      pages += 1
    } while step != nil && pages < 10
    #expect(found == ["/a.txt:1", "/a.txt:3", "/b.txt:1"])

    let all = try await run("grep", .object(["pattern": "foo"]), context, as: GrepOutput.self)
    #expect(all.matches.count == 3 && all.cursor == nil)
    let find = try await run("find", .object(["glob": "/*.txt"]), context, as: FindOutput.self)
    #expect(find.paths == ["/a.txt", "/b.txt"] && find.cursor == nil)
  }

  // Past the deadline a search fails; it never hands back a partial page.
  // The deadline races the whole search, so an await that never returns
  // ends there too.
  @Test func aSearchWhoseReadNeverReturnsFailsAtTheDeadline() async throws {
    let context = try makeContext()
    let target = SpaceToolContext.Target(backend: StalledReads(), path: "/", machine: nil)
    let failure = try await failureAtDeadline { try await SpaceToolbox.search(grepQuery("x"), target, context) }
    #expect(failure.advanced >= SearchLimits.deadline)
    #expect({ if case .failed(code: .unavailable, _, _, _) = failure.error { true } else { false } }(), "\(failure.advanced) \(failure.outcome)")
  }

  private func grepQuery(_ pattern: String) -> SearchQuery {
    SearchQuery(mode: .grep, pattern: pattern, root: "/", scope: "test")
  }

  /// Runs `search` under a test clock, advancing it a second at a time until
  /// the search ends; how far the clock went and how the search failed.
  private func failureAtDeadline(
    _ search: @escaping @Sendable () async throws -> SearchPage,
  ) async throws -> (advanced: Duration, error: ToolRunError?, outcome: String) {
    let clock = VirtualClock()
    let done = Mutex(false)
    let task = Task {
      defer { done.withLock { $0 = true } }
      return try await withDependencies { $0.continuousClock = clock } operation: { try await search() }
    }
    var advanced = Duration.zero
    while !done.withLock({ $0 }), advanced < .seconds(600) {
      await clock.advance(by: .seconds(1))
      advanced += .seconds(1)
      for _ in 0 ..< 20 { await Task.yield() }
    }
    switch await task.result {
    case let .success(page): return (advanced, nil, "\(page)")
    case let .failure(error): return (advanced, error as? ToolRunError, "\(error)")
    }
  }

  // grep's dialect is ICU regular expressions (NSRegularExpression).
  @Test func grepSpeaksTheICUDialect() async throws {
    let context = try makeContext()
    _ = try await seedFile("/d.txt", "Price: 42 USD\ncafé crème\nfoobar\nbarfoo\nTAB\there\n", context)
    let cases: [(String, [Int])] = [
      (#"\d{2}"#, [1]),
      (#"^\w+:"#, [1]),
      (#"[[:alpha:]]+ crème$"#, [2]),
      (#"\p{L}+é\b"#, [2]),
      (#"foo(?=bar)"#, [3]),
      (#"(?<=bar)foo"#, [4]),
      (#"(?i)^tab\t"#, [5]),
      (#"\bbar"#, [4]),
    ]
    for (pattern, lines) in cases {
      let output = try await run("grep", .object(["pattern": .string(pattern)]), context, as: GrepOutput.self)
      #expect(output.matches.map(\.line) == lines, "\(pattern)")
    }
  }
}

// A backend whose every read waits until its task is cancelled.
private struct StalledReads: SpaceVFS {
  private func entry(_ name: String, _ kind: SpaceFS.Entry.Kind) -> SpaceFS.Entry {
    SpaceFS.Entry(name: name, kind: kind, size: 1, lineCount: nil, token: VersionToken(Data("t".utf8)), mtime: Date())
  }

  func list(_ path: String) async throws -> (VersionToken, [SpaceFS.Entry]) {
    (VersionToken(Data("t".utf8)), path == "/" ? [entry("a.txt", .file)] : [])
  }

  func stat(_ path: String) async throws -> SpaceFS.Entry {
    path == "/" ? entry("", .directory) : entry("a.txt", .file)
  }

  func read(_: String) async throws -> (VersionToken, Data) { (VersionToken(Data("t".utf8)), try await reader("").read(at: 0, count: 0)) }

  func reader(_: String) async throws -> any SpaceFileReader { Stalled() }

  private struct Stalled: SpaceFileReader {
    func read(at _: Int, count _: Int) async throws -> Data {
      let (never, continuation) = AsyncStream<Never>.makeStream()
      defer { withExtendedLifetime(continuation) {} }
      for await _ in never {}
      throw CancellationError()
    }
  }

  func write(_: String, _: Data, ifMatch _: VersionToken?) async throws -> VersionToken { VersionToken(Data("t".utf8)) }
  func delete(_: String, ifMatch _: VersionToken?) async throws {}
  func move(_: String, to _: String) async throws {}
}
