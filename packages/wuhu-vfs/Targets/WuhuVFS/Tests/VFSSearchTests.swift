import Foundation
import Testing
import WuhuVFS

/// VFS-4: the protocol `find`/`grep` default tree-walk — glob matching,
/// `.gitignore` honoring, and the result-cap / scan-cap / resume-cursor paging.
struct VFSSearchTests {
  private func seeded() async throws -> NodeTreeVFS {
    let root = InMemoryVFSNode()
    try await root.seedFile(at: try path(["a.txt"]), data: Data("alpha one\nalpha two".utf8))
    try await root.seedFile(at: try path(["src", "main.swift"]), data: Data("let x = 1\n// alpha".utf8))
    try await root.seedFile(at: try path(["src", "util.swift"]), data: Data("let y = 2".utf8))
    try await root.seedFile(at: try path(["src", "nested", "deep.swift"]), data: Data("alpha deep".utf8))
    try await root.seedFile(at: try path(["README.md"]), data: Data("# readme".utf8))
    return NodeTreeVFS(root: root)
  }

  // MARK: - Find

  @Test func `find matches a glob across the tree`() async throws {
    let vfs = try await seeded()
    let page = try await vfs.find(root: try path([]), pattern: "**/*.swift", matchLimit: 100, entryLimit: 1000, step: nil)
    #expect(page.paths.sorted() == ["src/main.swift", "src/nested/deep.swift", "src/util.swift"])
    #expect(page.next == nil)
    #expect(!page.matchLimitReached)
  }

  @Test func `find honors the match-limit and returns a resume cursor`() async throws {
    let vfs = try await seeded()
    let page = try await vfs.find(root: try path([]), pattern: "**/*.swift", matchLimit: 2, entryLimit: 1000, step: nil)
    #expect(page.paths.count == 2)
    #expect(page.matchLimitReached)
    #expect(page.next != nil)

    // Resuming yields the remaining match.
    let next = try await vfs.find(root: try path([]), pattern: "**/*.swift", matchLimit: 2, entryLimit: 1000, step: page.next)
    let all = Set(page.paths + next.paths)
    #expect(all == ["src/main.swift", "src/nested/deep.swift", "src/util.swift"])
    #expect(next.next == nil)
  }

  @Test func `find honors the entry-limit by aborting the scan`() async throws {
    let vfs = try await seeded()
    // Only scan a few entries — far fewer than the tree holds — so the walk
    // pauses with an entry-limit cursor regardless of matches.
    let page = try await vfs.find(root: try path([]), pattern: "**/*", matchLimit: 1000, entryLimit: 2, step: nil)
    #expect(page.entryLimitReached)
    #expect(page.next != nil)
    #expect(page.paths.count <= 2)
  }

  // MARK: - Grep

  @Test func `grep finds matching lines with paths and line numbers`() async throws {
    let vfs = try await seeded()
    let page = try await vfs.grep(root: try path([]), pattern: "alpha", options: GrepOptions(), matchLimit: 100, entryLimit: 1000, step: nil)
    let hits = page.lines.filter { !$0.isContext }.map { "\($0.file):\($0.lineNumber)" }.sorted()
    #expect(hits == ["a.txt:1", "a.txt:2", "src/main.swift:2", "src/nested/deep.swift:1"])
    #expect(page.matchCount == 4)
  }

  @Test func `grep file glob restricts the searched files`() async throws {
    let vfs = try await seeded()
    let page = try await vfs.grep(
      root: try path([]),
      pattern: "alpha",
      options: GrepOptions(fileGlob: "**/*.swift"),
      matchLimit: 100,
      entryLimit: 1000,
      step: nil,
    )
    let files = Set(page.lines.map(\.file))
    #expect(files == ["src/main.swift", "src/nested/deep.swift"])
  }

  @Test func `grep literal and ignoreCase`() async throws {
    let vfs = try await seeded()
    let literal = try await vfs.grep(root: try path([]), pattern: "ALPHA", options: GrepOptions(ignoreCase: true, literal: true), matchLimit: 100, entryLimit: 1000, step: nil)
    #expect(literal.matchCount == 4)
  }

  @Test func `grep context lines surround the match`() async throws {
    let vfs = try await seeded()
    let page = try await vfs.grep(root: try path(["src", "main.swift"]), pattern: "alpha", options: GrepOptions(contextLines: 1), matchLimit: 100, entryLimit: 1000, step: nil)
    // The match is on line 2; with 1 line of context, line 1 is included as context.
    #expect(page.lines.contains { $0.lineNumber == 1 && $0.isContext })
    #expect(page.lines.contains { $0.lineNumber == 2 && !$0.isContext })
  }

  @Test func `grep honors the match-limit`() async throws {
    let vfs = try await seeded()
    let page = try await vfs.grep(root: try path([]), pattern: "alpha", options: GrepOptions(), matchLimit: 2, entryLimit: 1000, step: nil)
    #expect(page.matchCount == 2)
    #expect(page.matchLimitReached)
  }

  // MARK: - grep resume (the data-loss regression: pages must union to the full set)

  /// A single file with MORE matches than the limit: paging through it via the
  /// resume cursor must yield every match exactly once, with no mid-file losses.
  /// This is the regression for the per-file-cursor bug — grep emits per line, so
  /// a match-limit hit mid-file must not skip the boundary file's remaining lines.
  @Test func `grep paging over one over-limit file unions to the full result`() async throws {
    let root = InMemoryVFSNode()
    // 5 matching lines (interleaved with non-matches) in ONE file.
    let body = (1 ... 9).map { $0 % 2 == 1 ? "needle \($0)" : "skip \($0)" }.joined(separator: "\n")
    try await root.seedFile(at: try path(["big.txt"]), data: Data(body.utf8))
    let vfs = NodeTreeVFS(root: root)

    let unpaged = try await vfs.grep(root: try path([]), pattern: "needle", options: GrepOptions(), matchLimit: 100, entryLimit: 1000, step: nil)
    #expect(unpaged.matchCount == 5)
    let full = unpaged.lines.map { "\($0.file):\($0.lineNumber)" }

    // Page through with matchLimit 2; collect until exhausted.
    var collected: [String] = []
    var cursor: SearchCursor? = nil
    var pages = 0
    repeat {
      let page = try await vfs.grep(root: try path([]), pattern: "needle", options: GrepOptions(), matchLimit: 2, entryLimit: 1000, step: cursor)
      collected += page.lines.map { "\($0.file):\($0.lineNumber)" }
      cursor = page.next
      pages += 1
      #expect(pages < 10, "paging did not terminate")
    } while cursor != nil

    // The union of the pages equals the un-paginated result, in order, no dups.
    #expect(collected == full)
    #expect(pages == 3) // 5 matches / 2 per page = 3 pages
  }

  /// Paging across a FILE boundary: the limit lands mid-first-file, so resume
  /// must finish the first file before moving to the second — no lost matches at
  /// the boundary.
  @Test func `grep paging across a file boundary loses no matches`() async throws {
    let root = InMemoryVFSNode()
    try await root.seedFile(at: try path(["a.txt"]), data: Data("needle a1\nneedle a2\nneedle a3".utf8))
    try await root.seedFile(at: try path(["b.txt"]), data: Data("needle b1\nneedle b2".utf8))
    let vfs = NodeTreeVFS(root: root)

    let unpaged = try await vfs.grep(root: try path([]), pattern: "needle", options: GrepOptions(), matchLimit: 100, entryLimit: 1000, step: nil)
    #expect(unpaged.matchCount == 5)
    let full = Set(unpaged.lines.map { "\($0.file):\($0.lineNumber)" })

    var collected: [String] = []
    var cursor: SearchCursor? = nil
    var pages = 0
    repeat {
      let page = try await vfs.grep(root: try path([]), pattern: "needle", options: GrepOptions(), matchLimit: 2, entryLimit: 1000, step: cursor)
      collected += page.lines.map { "\($0.file):\($0.lineNumber)" }
      cursor = page.next
      pages += 1
      #expect(pages < 10, "paging did not terminate")
    } while cursor != nil

    // Every match exactly once across the boundary.
    #expect(Set(collected) == full)
    #expect(collected.count == 5)
  }

  /// A resumed single-file grep continues mid-file from the cursor.
  @Test func `grep paging over a single-file root unions to the full result`() async throws {
    let root = InMemoryVFSNode()
    try await root.seedFile(at: try path(["only.txt"]), data: Data((1 ... 5).map { "needle \($0)" }.joined(separator: "\n").utf8))
    let vfs = NodeTreeVFS(root: root)

    var collected: [Int] = []
    var cursor: SearchCursor? = nil
    var pages = 0
    repeat {
      let page = try await vfs.grep(root: try path(["only.txt"]), pattern: "needle", options: GrepOptions(), matchLimit: 2, entryLimit: 1000, step: cursor)
      collected += page.lines.filter { !$0.isContext }.map(\.lineNumber)
      cursor = page.next
      pages += 1
      #expect(pages < 10, "paging did not terminate")
    } while cursor != nil

    #expect(collected == [1, 2, 3, 4, 5])
    #expect(pages == 3)
  }

  // MARK: - Gitignore

  @Test func `find and grep honor gitignore`() async throws {
    let root = InMemoryVFSNode()
    try await root.seedFile(at: try path([".gitignore"]), data: Data("ignored/\n*.log".utf8))
    try await root.seedFile(at: try path(["keep.swift"]), data: Data("alpha keep".utf8))
    try await root.seedFile(at: try path(["debug.log"]), data: Data("alpha log".utf8))
    try await root.seedFile(at: try path(["ignored", "secret.swift"]), data: Data("alpha secret".utf8))
    let vfs = NodeTreeVFS(root: root)

    let found = try await vfs.find(root: try path([]), pattern: "**/*", matchLimit: 100, entryLimit: 1000, step: nil)
    #expect(!found.paths.contains("debug.log"))
    #expect(!found.paths.contains("ignored/secret.swift"))
    #expect(found.paths.contains("keep.swift"))

    let grepped = try await vfs.grep(root: try path([]), pattern: "alpha", options: GrepOptions(), matchLimit: 100, entryLimit: 1000, step: nil)
    #expect(Set(grepped.lines.map(\.file)) == ["keep.swift"])
  }

  @Test func `well-known build directories are skipped`() async throws {
    let root = InMemoryVFSNode()
    try await root.seedFile(at: try path(["src.swift"]), data: Data("x".utf8))
    try await root.seedFile(at: try path([".git", "config"]), data: Data("x".utf8))
    try await root.seedFile(at: try path(["node_modules", "pkg", "index.js"]), data: Data("x".utf8))
    let vfs = NodeTreeVFS(root: root)
    let page = try await vfs.find(root: try path([]), pattern: "**/*", matchLimit: 100, entryLimit: 1000, step: nil)
    #expect(page.paths == ["src.swift"])
  }
}
