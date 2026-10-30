import Clocks
#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import FileSearch
import Synchronization
import Testing

extension Data {
  fileprivate func repeated(_ count: Int) -> Data {
    (0 ..< count).reduce(into: Data()) { result, _ in result.append(self) }
  }
}

@Suite struct EngineTests {
  private func find(_ glob: String, _ root: String = "/", hidden: Bool = false, noIgnore: Bool = false, limit: Int? = nil) -> SearchQuery {
    SearchQuery(mode: .find, pattern: glob, root: root, scope: "tree", hidden: hidden, noIgnore: noIgnore, limit: limit)
  }

  private func grep(_ pattern: String, _ root: String = "/", scope: String = "tree", hidden: Bool = false, limit: Int? = nil) -> SearchQuery {
    SearchQuery(mode: .grep, pattern: pattern, root: root, scope: scope, hidden: hidden, limit: limit)
  }

  /// Every page of `query`, following cursors to the end.
  private func pages(_ query: SearchQuery, _ tree: MemoryTree) async throws -> [SearchPage] {
    var query = query
    var pages: [SearchPage] = []
    repeat {
      let page = try await query.run(in: tree)
      pages.append(page)
      query.step = page.cursor
    } while query.step != nil && pages.count < 100_000
    return pages
  }

  private func hits(_ query: SearchQuery, _ tree: MemoryTree) async throws -> [String] {
    try await pages(query, tree).flatMap(\.hits).map { hit in hit.line.map { "\(hit.path):\($0)" } ?? hit.path }
  }

  private func failure(_ query: SearchQuery, _ tree: MemoryTree) async -> SearchError.Code? {
    do {
      _ = try await query.run(in: tree)
      return nil
    } catch {
      return (error as? SearchError)?.code
    }
  }

  @Test func theWalkIsDepthFirstWithSiblingsInByteOrder() async throws {
    let tree = MemoryTree(files: ["/b": "", "/a-b": "", "/a/z": "", "/a0": "", "/f": "", "/\u{E9}": "", "/e\u{301}x": "", "/a/y/x": ""])
    let found = try await hits(find("**"), tree)
    #expect(found.map(\.utf8.count) == [6, 4, 4, 3, 2, 5, 2, 3])
    #expect(found.prefix(5) == ["/a/y/x", "/a/z", "/a-b", "/a0", "/b"])
  }

  @Test func pagingByAnyLimitYieldsTheOnePageResult() async throws {
    var files: [String: String] = [:]
    for name in ["a", "b/c", "b/d/e", "f", "g/h"] {
      files["/\(name).txt"] = "foo 1\nbar\nfoo 2\n\nfoo 3"
    }
    let tree = MemoryTree(files: files)
    let allFound = try await hits(find("*.txt"), tree)
    let allMatched = try await hits(grep("foo"), tree)
    #expect(allFound.count == 5 && allMatched.count == 15)
    for limit in 1 ... 4 {
      #expect(try await hits(find("*.txt", limit: limit), tree) == allFound, "find \(limit)")
      #expect(try await hits(grep("foo", limit: limit), tree) == allMatched, "grep \(limit)")
    }
    let full = try await grep("foo").run(in: tree)
    #expect(full.cursor == nil && full.scanned == 8, "five files and three directories")
  }

  @Test func aCursorPointsAtTheFirstHitThePageDidNotHold() async throws {
    let tree = MemoryTree(files: ["/a.txt": "foo\nfoo\n", "/b.txt": "nothing"])
    let page = try await grep("foo", limit: 2).run(in: tree)
    #expect(page.hits.count == 2 && page.cursor == nil, "exactly the limit, nothing more")
    let found = try await find("*.txt", limit: 2).run(in: tree)
    #expect(found.cursor == nil)
  }

  @Test func grepLinesAreNumberedOnceAndStripTheCarriageReturn() async throws {
    let tree = MemoryTree(files: ["/crlf.txt": "one\r\ntwo$\r\n", "/tail.txt": "x\n\nx"])
    let page = try await grep("o\\$?$").run(in: tree)
    #expect(page.hits.map(\.text) == ["two$"])
    #expect(try await hits(grep("^$"), tree) == ["/tail.txt:2"], "no empty line after the final newline")
    #expect(try await hits(grep("^"), tree) == ["/crlf.txt:1", "/crlf.txt:2", "/tail.txt:1", "/tail.txt:2", "/tail.txt:3"])
  }

  @Test func hiddenEntriesAreSkippedAndReportedUnlessAsked() async throws {
    let tree = MemoryTree(files: ["/.env": "foo", "/.cache/x": "foo", "/a": "foo"])
    let page = try await grep("foo").run(in: tree)
    #expect(page.hits.map(\.path) == ["/a"])
    #expect(page.skipped == [SearchSkip(reason: .hidden, count: 2, example: "/.cache")])
    #expect(try await hits(grep("foo", hidden: true), tree) == ["/.cache/x:1", "/.env:1", "/a:1"])
    #expect(try await hits(grep("foo", "/.env"), tree) == ["/.env:1"], "a root is searched whatever it is")
    #expect(try await hits(find("*env", "/.env"), tree) == ["/.env"], "a file root matches its name")
  }

  @Test func gitignoreRulesApplyFromTheRepositoryDown() async throws {
    let tree = MemoryTree(files: [
      "/repo/.git/HEAD": "",
      "/repo/.gitignore": "*.log\n!keep.log\nbuild/\n/top.txt\n",
      "/repo/top.txt": "",
      "/repo/sub/top.txt": "",
      "/repo/sub/a.log": "",
      "/repo/sub/keep.log": "",
      "/repo/sub/build/out": "",
      "/repo/sub/build.txt": "",
      "/repo/sub/deep/.gitignore": "!*.log\nkeep.log\n",
      "/repo/sub/deep/b.log": "",
      "/repo/sub/deep/keep.log": "",
    ])
    let whole = try await find("*", "/repo").run(in: tree)
    #expect(whole.hits.map(\.path) == ["/repo/sub/build.txt", "/repo/sub/deep/b.log", "/repo/sub/keep.log", "/repo/sub/top.txt"])
    #expect(whole.skipped.map(\.reason) == [.hidden, .ignored])
    #expect(try await hits(find("*", "/repo/sub"), tree) == ["/repo/sub/build.txt", "/repo/sub/deep/b.log", "/repo/sub/keep.log", "/repo/sub/top.txt"], "rules above the root apply")
    #expect(try await hits(find("*", "/repo/sub", noIgnore: true), tree).count == 7)

    let outside = MemoryTree(files: ["/x/.gitignore": "*.log\n", "/x/y/a.log": "", "/x/y/z/.gitignore": "b.*\n", "/x/y/z/b.txt": ""])
    #expect(try await hits(find("*", "/x/y"), outside) == ["/x/y/a.log"], "no repository: only the walked tree's own .gitignore files")
  }

  @Test func filesItCannotReadAreSkippedWithAReason() async throws {
    var nodes: [String: MemoryTree.Node] = [
      "/bin": .file(Data([0x66, 0x6F, 0x6F, 0, 1])),
      "/locked": .unreadableDirectory,
      "/secret": .unreadableFile,
      "/link": .other,
      "/text": .file(Data("foo\n".utf8)),
    ]
    nodes["/long"] = .file(Data(("foo\n" + String(repeating: "x", count: SearchLimits.lineBytes + 1) + "\nfoo").utf8))
    let tree = MemoryTree(nodes)
    let page = try await grep("foo").run(in: tree)
    #expect(page.hits.map { "\($0.path):\($0.line!)" } == ["/long:1", "/text:1"], "a long line ends the file, not what it held before")
    #expect(page.skipped == [
      SearchSkip(reason: .binary, count: 1, example: "/bin"),
      SearchSkip(reason: .longLine, count: 1, example: "/long"),
      SearchSkip(reason: .unreadable, count: 2, example: "/locked"),
    ])
    #expect(try await hits(find("l*"), tree) == ["/link", "/long"])
  }

  @Test func shownLinesAreClampedOnAScalarBoundary() async throws {
    let line = "foo" + String(repeating: "é", count: 2000)
    let tree = MemoryTree(files: ["/a": line])
    let text = try #require(try await grep("foo").run(in: tree).hits.first?.text)
    #expect(text.hasSuffix("…[line clamped: 4003 bytes]"))
    #expect(text.utf8.count - "…[line clamped: 4003 bytes]".utf8.count == 499)
  }

  @Test func aPageEndsOnItsEntryBudget() async throws {
    var files: [String: String] = [:]
    for index in 0 ..< SearchLimits.pageEntries + 5 {
      files["/d/\(String(index + 100_000))"] = ""
    }
    let tree = MemoryTree(files: files)
    let all = try await pages(find("nothing"), tree)
    #expect(all.map(\.scanned) == [SearchLimits.pageEntries, 6])
    #expect(all.first?.cursor != nil && all.last?.cursor == nil)
  }

  @Test func aPageListsNoMoreChildrenThanItsEntryBudget() async throws {
    var files: [String: String] = ["/big/zz/needle": ""]
    for index in 0 ..< 3 * SearchLimits.pageEntries {
      files["/big/\(String(index + 100_000))"] = ""
    }
    let tree = MemoryTree(files: files)
    var query = find("needle", limit: 1)
    var listed: [Int] = []
    var found: [String] = []
    repeat {
      let before = tree.childrenListed
      let page = try await query.run(in: tree)
      listed.append(tree.childrenListed - before)
      found += page.hits.map(\.path)
      query.step = page.cursor
    } while query.step != nil
    #expect(found == ["/big/zz/needle"])
    #expect(listed.count == 4)
    for count in listed {
      #expect(count <= SearchLimits.pageEntries + 3, "the root, the directory and the page's own share")
    }
  }

  @Test func aPageEndsOnItsReadBudget() async throws {
    let chunk = Data((String(repeating: "a", count: 1023) + "\n").utf8).repeated(1024)
    var nodes: [String: MemoryTree.Node] = [:]
    for index in 0 ..< 20 {
      nodes["/f\(index + 10)"] = .file(chunk)
    }
    nodes["/f30"] = .file(Data("needle".utf8))
    let tree = MemoryTree(nodes)
    let first = try await grep("needle").run(in: tree)
    #expect(first.hits.isEmpty && first.cursor != nil)
    #expect(tree.bytesRead <= SearchLimits.pageReadBytes)
    #expect(try await hits(grep("needle"), tree) == ["/f30:1"])
  }

  @Test func binaryProbesCountAgainstTheReadBudget() async throws {
    let binary = Data([0]) + Data(repeating: 0x61, count: SearchLimits.lineBytes - 1)
    var nodes: [String: MemoryTree.Node] = ["/zz": .file(Data("needle".utf8))]
    for index in 0 ..< 400 {
      nodes["/b\(index + 1000)"] = .file(binary)
    }
    let tree = MemoryTree(nodes)
    let first = try await grep("needle").run(in: tree)
    #expect(first.hits.isEmpty && first.cursor != nil)
    #expect(tree.bytesRead <= SearchLimits.pageReadBytes)
    #expect(first.skipped.first { $0.reason == .binary }.map(\.count) == SearchLimits.pageReadBytes / SearchLimits.lineBytes)
    #expect(try await hits(grep("needle"), tree) == ["/zz:1"])
  }

  @Test func gitignoreReadsCountAgainstTheReadBudget() async throws {
    let rules = String(repeating: "# " + String(repeating: "x", count: 1021) + "\n", count: 60)
    var files: [String: String] = ["/repo/.git/HEAD": "", "/repo/zz/needle": ""]
    for index in 0 ..< 400 {
      files["/repo/d\(index + 1000)/.gitignore"] = rules
    }
    let tree = MemoryTree(files: files)
    let first = try await find("needle", "/repo").run(in: tree)
    #expect(first.hits.isEmpty && first.cursor != nil)
    #expect(tree.bytesRead <= SearchLimits.pageReadBytes)
    #expect(try await hits(find("needle", "/repo"), tree) == ["/repo/zz/needle"])

    let large = MemoryTree(files: ["/r/.git/HEAD": "", "/r/.gitignore": "a\n" + String(repeating: "#", count: SearchLimits.ignoreFileBytes), "/r/a": ""])
    let page = try await find("a", "/r").run(in: large)
    #expect(page.hits.map(\.path) == ["/r/a"], "a .gitignore at the cap is not read")
    #expect(page.skipped.contains { $0.reason == .unreadable && $0.example == "/r/.gitignore" })
  }

  @Test func gitignoreFilesAboveTheRootTakeAtMostTheirShareOfTheReadBudget() async throws {
    let rules = "*.log\n" + String(repeating: "#", count: SearchLimits.ignoreFileBytes - 10) + "\n"
    var files: [String: String] = ["/.git/HEAD": ""]
    var directory = ""
    for depth in 0 ..< 256 {
      directory += "/d\(depth)"
      files[directory + "/.gitignore"] = rules
    }
    let root = directory + "/root"
    files[root + "/a.log"] = ""
    files[root + "/b.txt"] = ""
    let tree = MemoryTree(files: files)
    let fitting = SearchLimits.ancestorIgnoreBytes / SearchLimits.ignoreFileBytes
    for _ in 0 ..< 2 {
      let before = tree.bytesRead
      let page = try await find("*", root).run(in: tree)
      #expect(page.hits.map(\.path) == [root + "/b.txt"], "the outermost rules still apply")
      #expect(page.skipped.first { $0.reason == .unreadable }?.count == 256 - fitting)
      #expect(tree.bytesRead - before <= SearchLimits.ancestorIgnoreBytes)
    }
  }

  @Test func aPageEndsOnItsByteBudget() async throws {
    let tree = MemoryTree(files: ["/a": String(repeating: String(repeating: "x", count: 600) + "\n", count: 1000)])
    let all = try await pages(grep("x", limit: 1000), tree)
    #expect(all.count > 1)
    for page in all {
      let size = try JSONEncoder().encode(page).count
      #expect(size <= SearchLimits.pageBytes + 1024)
    }
    #expect(all.flatMap(\.hits).map(\.line) == Array(1 ... 1000))
  }

  @Test func aLargerLimitIsCapped() async throws {
    let tree = MemoryTree(files: ["/a": String(repeating: "x\n", count: 1500)])
    let page = try await grep("x", limit: 5000).run(in: tree)
    #expect(page.hits.count == SearchLimits.maxLimit && page.cursor != nil)
  }

  @Test func malformedQueriesAreTypedErrors() async throws {
    let tree = MemoryTree(files: ["/a.txt": "foo\nfoo"])
    #expect(await failure(grep("(", "/"), tree) == .invalidPattern)
    #expect(await failure(find("[a", "/"), tree) == .invalidGlob)
    #expect(await failure(grep("x", limit: 0), tree) == .invalidLimit)
    #expect(await failure(grep("x", "/missing"), tree) == .notFound)
    #expect(await failure(grep(String(repeating: "a", count: SearchLimits.patternBytes + 1)), tree) == .invalidPattern)

    let cursor = try #require(try await grep("foo", limit: 1).run(in: tree).cursor)
    var other = grep("fo+", limit: 1)
    other.step = cursor
    #expect(await failure(other, tree) == .invalidStep, "a step is bound to its query")
    var hidden = grep("foo", hidden: true, limit: 1)
    hidden.step = cursor
    #expect(await failure(hidden, tree) == .invalidStep)
    var elsewhere = grep("foo", scope: "another tree", limit: 1)
    elsewhere.step = cursor
    #expect(await failure(elsewhere, tree) == .invalidStep, "and to its scope")
    var same = grep("foo", limit: 7)
    same.step = cursor
    #expect(try await same.run(in: tree).hits.map(\.line) == [2], "but not to its limit")
    same.step = "s2.bm90IGEgY3Vyc29y"
    #expect(await failure(same, tree) == .invalidStep)
  }

  @MainActor @Test func aSearchPastTheDeadlineFailsEvenWhenAReadNeverReturns() async throws {
    let tree = MemoryTree(["/a": .file(Data("x".utf8)), "/b": .stalled])
    let (code, advanced) = await underTestClock(grep("x"), tree)
    #expect(code == .timeout)
    #expect(advanced >= SearchLimits.deadline)
  }

  // The deadline cancels a match stuck backtracking. (ICU on Linux abandons
  // such a match by itself after about a second, as no match; so the clock
  // jumps straight to the deadline.)
  @MainActor @Test func aBacktrackingMatchFailsAtTheDeadline() async throws {
    let tree = MemoryTree(files: ["/a": "fine\n" + String(repeating: "a", count: 64) + "!\n"])
    let clock = TestClock()
    let done = Mutex(false)
    let search = Task {
      defer { done.withLock { $0 = true } }
      return try await grep("^(a+)+$").run(in: tree, clock: clock)
    }
    var step = SearchLimits.deadline
    while !done.withLock({ $0 }) {
      await clock.advance(by: step)
      step = .seconds(1)
      for _ in 0 ..< 20 {
        await Task.yield()
      }
    }
    switch await search.result {
    case .success: Issue.record("finished before the deadline")
    case let .failure(error): #expect((error as? SearchError)?.code == .timeout)
    }
  }

  /// Runs `query` under a test clock advanced a second at a time until the
  /// search ends: how it failed, and how far the clock went.
  @MainActor private func underTestClock(_ query: SearchQuery, _ tree: MemoryTree) async -> (SearchError.Code?, Duration) {
    let clock = TestClock()
    let done = Mutex(false)
    let search = Task {
      defer { done.withLock { $0 = true } }
      return try await query.run(in: tree, clock: clock)
    }
    var advanced = Duration.zero
    while !done.withLock({ $0 }), advanced < .seconds(600) {
      await clock.advance(by: .seconds(1))
      advanced += .seconds(1)
      for _ in 0 ..< 20 {
        await Task.yield()
      }
    }
    switch await search.result {
    case .success: return (nil, advanced)
    case let .failure(error): return ((error as? SearchError)?.code, advanced)
    }
  }
}
