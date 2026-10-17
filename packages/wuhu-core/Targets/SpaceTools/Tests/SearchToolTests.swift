import Clocks
import Dependencies
import Foundation
import JSONValue
import SpaceContract
import enum SpaceCore.SpaceError
import SpaceFS
@testable import SpaceTools
import Synchronization
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

  @Test func stepsAreBoundToTheirSearchAndMalformedOnesAreRefused() async throws {
    let context = try makeContext()
    try await seedCorpus(context)
    let find = try await run("find", .object(["glob": "/**", "matchLimit": 1]), context, as: FindOutput.self)
    let findStep = try #require(find.cursor)
    let grep = try await run("grep", .object(["pattern": "foo", "matchLimit": 1]), context, as: GrepOutput.self)
    let grepStep = try #require(grep.cursor)
    for input in [
      JSONValue.object(["glob": "/**", "step": "/docs/b.txt"]),
      .object(["glob": "/**", "step": "s1.!!"]),
      .object(["glob": "/**", "step": "s1."]),
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
    _ = try await seedFile("/many.txt", String(repeating: "x\n", count: SearchBounds.matchLimit + 5), context)
    let page = try await run("grep", .object(["pattern": "x", "matchLimit": 50000, "entryLimit": 10_000_000]), context, as: GrepOutput.self)
    #expect(page.matches.count == SearchBounds.matchLimit)
    let rest = try await run(
      "grep", .object(["pattern": "x", "matchLimit": 50000, "step": .string(try #require(page.cursor))]), context, as: GrepOutput.self,
    )
    #expect(rest.matches.count == 5)
    #expect(rest.cursor == nil)
  }

  @Test func oversizedFilesAreListedAsSkippedAndLongLinesClamped() async throws {
    let context = try makeContext()
    _ = try await seedFile("/a/big.log", String(repeating: "foo\n", count: SearchBounds.fileBytes / 4 + 1), context)
    _ = try await seedFile("/a/long.txt", "foo" + String(repeating: "é", count: 2000), context)
    let output = try await run("grep", .object(["pattern": "foo"]), context, as: GrepOutput.self)
    #expect(output.skipped == [SkippedFile(path: "/a/big.log", bytes: SearchBounds.fileBytes + 4, reason: "tooLarge")])
    let text = try #require(output.matches.first?.text)
    #expect(output.matches.map(\.path) == ["/a/long.txt"])
    #expect(text.hasPrefix("foo") && text.contains("[line clamped: 4003 bytes]"))
    #expect(text.utf8.count < 600)

    let none = try await run("grep", .object(["pattern": "foo", "path": "/a/long.txt"]), context, as: GrepOutput.self)
    #expect(none.skipped == nil)
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
    let target = SpaceToolContext.Target(backend: StalledReads(), path: "/", machine: nil)
    let failure = try await failureAtDeadline { try await SpaceToolbox.spaceGrep(try grepInput("x"), target) }
    #expect(failure.advanced >= SearchBounds.deadline)
    #expect({ if case .failed(code: .unavailable, _, _, _) = failure.error { true } else { false } }(), "\(failure.error)")
  }

  @Test func aBacktrackingMatchFailsAtTheDeadline() async throws {
    let context = try makeContext()
    _ = try await seedFile("/costly.txt", "fine\n" + String(repeating: "a", count: 64) + "!\n", context)
    let target = try context.resolve("/")
    let failure = try await failureAtDeadline { try await SpaceToolbox.spaceGrep(try grepInput("^(a+)+$"), target) }
    #expect({ if case .failed(code: .unavailable, _, _, _) = failure.error { true } else { false } }(), "\(failure.error)")
  }

  private func grepInput(_ pattern: String) throws -> GrepInput {
    try JSONValueDecoder().decode(GrepInput.self, from: .object(["pattern": .string(pattern)]))
  }

  /// Runs `search` under a test clock, advancing it a second at a time until
  /// the search ends; how far the clock went and how the search failed.
  private func failureAtDeadline(
    _ search: @escaping @Sendable () async throws -> JSONValue,
  ) async throws -> (advanced: Duration, error: ToolRunError?) {
    let clock = TestClock()
    let done = Mutex(false)
    let task = Task {
      defer { done.withLock { $0 = true } }
      return try await withDependencies { $0.continuousClock = clock } operation: { try await withSearchDeadline(search) }
    }
    var advanced = Duration.zero
    while !done.withLock({ $0 }), advanced < .seconds(600) {
      await clock.advance(by: .seconds(1))
      advanced += .seconds(1)
      for _ in 0 ..< 20 { await Task.yield() }
    }
    switch await task.result {
    case .success: return (advanced, nil)
    case let .failure(error): return (advanced, error as? ToolRunError)
    }
  }

  @Test func aStepIsBoundToTheBackendItsPathResolvedTo() async throws {
    let context = try makeContext()
    try await seedCorpus(context)
    let find = try await run("find", .object(["glob": "/**", "matchLimit": 1]), context, as: FindOutput.self)
    let grep = try await run("grep", .object(["pattern": ".", "matchLimit": 1]), context, as: GrepOutput.self)
    for (tool, input) in [
      ("find", JSONValue.object(["glob": "/**", "path": "wuhu://system/", "step": .string(try #require(find.cursor))])),
      ("grep", .object(["pattern": ".", "path": "wuhu://system/", "step": .string(try #require(grep.cursor))])),
    ] {
      let bad = await failure(tool, input, context)
      #expect({ if case .failed(code: .invalidArgument, _, _, _) = bad { true } else { false } }(), "\(tool)")
    }
  }

  @Test func aSizeOverTheBoundFoundOnReadIsSkipped() async throws {
    let big = Data(count: SearchBounds.fileBytes + 1)
    let tree = ListingTree(["/": ["big", "small"]], content: ["/big": big])
    #expect(try await searchable(tree, "/big", listedSize: 1) == .tooLarge(SearchBounds.fileBytes + 1), "the listing's size was stale")
    #expect(try await searchable(tree, "/small", listedSize: 1) == .text(Data("x".utf8)))
    #expect(try await searchable(tree, "/small", listedSize: SearchBounds.fileBytes + 9) == .tooLarge(SearchBounds.fileBytes + 9))
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

  @Test func theWalkStopsListingAtTheBoundAndPrunesWhatAStepPassed() async throws {
    let tree = ListingTree([
      "/": ["a", "b", "c"],
      "/a": ["1", "2"],
      "/b": ["1", "2"],
      "/c": ["1", "2"],
    ])
    let first = walk(tree, entryLimit: 1)
    var seen: [String] = []
    try await first.run(root: "/") { path, _ in seen.append(path); return true }
    #expect(seen == ["/a/1"])
    #expect(first.next == "/a/2")
    #expect(tree.listed == ["/", "/a"])

    tree.listed = []
    let second = walk(tree, entryLimit: 2, resume: "/b/2")
    seen = []
    try await second.run(root: "/") { path, _ in seen.append(path); return true }
    #expect(seen == ["/b/2", "/c/1"])
    #expect(second.next == "/c/2")
    #expect(tree.listed == ["/b", "/", "/c"], "/a is wholly before the step and never listed")
  }

  @Test func aWideDirectoryIsListedAPageAtATimeFromTheStep() async throws {
    let names = (0 ..< 300_000).map { String(format: "n%06d", $0) }
    let tree = ListingTree(["/": names])
    let first = walk(tree, entryLimit: 1)
    var seen: [String] = []
    try await first.run(root: "/") { path, _ in seen.append(path); return true }
    #expect(seen == ["/n000000"])
    #expect(first.next == "/n000001")
    #expect(tree.returned == SearchWalk.pageSize, "one page, not the directory")

    tree.returned = 0
    let deep = walk(tree, entryLimit: 3, resume: "/n250000")
    seen = []
    try await deep.run(root: "/") { path, _ in seen.append(path); return true }
    #expect(seen == ["/n250000", "/n250001", "/n250002"])
    #expect(tree.returned == SearchWalk.pageSize, "the page starts at the step")
  }

  // Full-path order: "/a-b" < "/a/z" because "-" < "/", the machine agent's order too.
  @Test func theWalkFollowsFullPathOrderAcrossDirectoryBoundaries() async throws {
    let tree = ListingTree(["/": ["a", "a-b", "a-c", "a0"], "/a": ["z"], "/a-c": ["y"]])
    var seen: [String] = []
    try await walk(tree, entryLimit: 10).run(root: "/") { path, _ in seen.append(path); return true }
    #expect(seen == ["/a-b", "/a-c/y", "/a/z", "/a0"])

    for (resume, rest) in [
      ("/a-b", ["/a-b", "/a-c/y", "/a/z", "/a0"]),
      ("/a-c/y", ["/a-c/y", "/a/z", "/a0"]),
      ("/a-c/", ["/a-c/y", "/a/z", "/a0"]),
      ("/a/z", ["/a/z", "/a0"]),
      ("/a0", ["/a0"]),
    ] {
      seen = []
      try await walk(tree, entryLimit: 10, resume: resume).run(root: "/") { path, _ in seen.append(path); return true }
      #expect(seen == rest, "from \(resume)")
    }
  }

  // SQLite's byte order, where Swift's `<` would call these two names equal.
  @Test func theWalkOrdersAndResumesByBytesNotCanonicalEquivalence() async throws {
    let decomposed = "e\u{301}", precomposed = "\u{E9}"
    let tree = ListingTree(["/": [precomposed, "f", decomposed]])
    var seen: [String] = []
    try await walk(tree, entryLimit: 10).run(root: "/") { path, _ in seen.append(path); return true }
    #expect(seen.map(\.utf8.count) == [4, 2, 3], "e\u{301}, f, \u{E9}")

    seen = []
    try await walk(tree, entryLimit: 10, resume: "/f").run(root: "/") { path, _ in seen.append(path); return true }
    #expect(seen == ["/f", "/" + precomposed])
    seen = []
    try await walk(tree, entryLimit: 10, resume: "/" + precomposed).run(root: "/") { path, _ in seen.append(path); return true }
    #expect(seen.map(\.utf8.count) == [3])
  }

  private func walk(_ tree: ListingTree, entryLimit: Int, resume: String? = nil) -> SearchWalk {
    SearchWalk(backend: tree, entryLimit: entryLimit, resume: resume)
  }
}

// Directories by path; every other name is a file of `size` bytes. Records
// each listing and how many entries the paged listings returned.
private final class ListingTree: SpaceVFS {
  let directories: [String: [String]]
  let size: Int
  let content: [String: Data]
  private let log = Mutex<(listed: [String], returned: Int)>(([], 0))

  init(_ directories: [String: [String]], size: Int = 1, content: [String: Data] = [:]) {
    self.directories = directories.mapValues { $0.sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) } }
    self.size = size
    self.content = content
  }

  var listed: [String] {
    get { log.withLock { $0.listed } }
    set { log.withLock { $0.listed = newValue } }
  }

  var returned: Int {
    get { log.withLock { $0.returned } }
    set { log.withLock { $0.returned = newValue } }
  }

  private func child(_ name: String, of path: String) -> String {
    path == "/" ? "/\(name)" : "\(path)/\(name)"
  }

  private func entry(_ name: String, at path: String) -> SpaceFS.Entry {
    SpaceFS.Entry(name: name, kind: directories[path] == nil ? .file : .directory, size: size, lineCount: nil, token: VersionToken(Data("t".utf8)), mtime: Date())
  }

  func list(_ path: String) async throws -> (VersionToken, [SpaceFS.Entry]) {
    log.withLock { $0.listed.append(path) }
    return (VersionToken(Data("t".utf8)), (directories[path] ?? []).map { entry($0, at: child($0, of: path)) })
  }

  func list(_ path: String, from: String, limit: Int) async throws -> (entries: [SpaceFS.Entry], next: String?) {
    let names = (directories[path] ?? []).drop { $0.utf8.lexicographicallyPrecedes(from.utf8) }
    let page = names.prefix(limit).map { entry($0, at: child($0, of: path)) }
    log.withLock {
      $0.listed.append(path)
      $0.returned += page.count
    }
    return (page, names.dropFirst(limit).first)
  }

  func stat(_ path: String) async throws -> SpaceFS.Entry {
    let parent = path.split(separator: "/").dropLast().joined(separator: "/")
    let name = String(path.split(separator: "/").last ?? "")
    guard path == "/" || directories["/" + parent]?.contains(name) == true else { throw SpaceError.notFound(path) }
    return entry(name, at: path)
  }

  func read(_ path: String) async throws -> (VersionToken, Data) { (VersionToken(Data("t".utf8)), content[path] ?? Data("x".utf8)) }
  func write(_: String, _: Data, ifMatch _: VersionToken?) async throws -> VersionToken { VersionToken(Data("t".utf8)) }
  func delete(_: String, ifMatch _: VersionToken?) async throws {}
  func move(_: String, to _: String) async throws {}
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

  func read(_: String) async throws -> (VersionToken, Data) {
    let (never, continuation) = AsyncStream<Never>.makeStream()
    defer { withExtendedLifetime(continuation) {} }
    for await _ in never {}
    throw CancellationError()
  }

  func write(_: String, _: Data, ifMatch _: VersionToken?) async throws -> VersionToken { VersionToken(Data("t".utf8)) }
  func delete(_: String, ifMatch _: VersionToken?) async throws {}
  func move(_: String, to _: String) async throws {}
}
