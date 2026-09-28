import Foundation

/// An opaque continuation cursor for a paged ``VirtualFileSystem/find(...)`` /
/// ``VirtualFileSystem/grep(...)``.
///
/// A search caps both the *results* it returns (match-limit) and the *entries*
/// it scans (entry-limit). When either cap is hit before the tree is exhausted,
/// the search returns a cursor; passing it back as `step` resumes from where the
/// previous page stopped. The cursor is opaque to callers — its `raw` is the
/// resume key (for the node-tree walk, the relative path of the last entry
/// scanned, so the next page skips up to and including it). Resumption is
/// best-effort over a filesystem that mutated between pages (`WuhuNewSpec.md:347`).
public struct SearchCursor: Sendable, Hashable, Codable {
  public var raw: String

  public init(raw: String) {
    self.raw = raw
  }
}

/// One page of a ``VirtualFileSystem/find(...)``.
public struct FindPage: Sendable, Hashable, Codable {
  /// Matching paths, relative to the search root, in walk order. Capped at the
  /// match-limit.
  public var paths: [String]
  /// Whether the match-limit was reached (more results may exist beyond this
  /// page).
  public var matchLimitReached: Bool
  /// Whether the entry-limit (entries scanned) was reached before the tree was
  /// exhausted.
  public var entryLimitReached: Bool
  /// A continuation cursor to resume the search, or `nil` when the tree was
  /// fully scanned (no more pages).
  public var next: SearchCursor?

  public init(paths: [String], matchLimitReached: Bool, entryLimitReached: Bool, next: SearchCursor?) {
    self.paths = paths
    self.matchLimitReached = matchLimitReached
    self.entryLimitReached = entryLimitReached
    self.next = next
  }
}

/// A single line matched by ``VirtualFileSystem/grep(...)``.
public struct GrepLine: Sendable, Hashable, Codable {
  /// File path relative to the search root.
  public var file: String
  /// 1-indexed line number.
  public var lineNumber: Int
  /// The line content (already LF-normalized; long lines are truncated by the
  /// tool layer, not here).
  public var line: String
  /// Whether this is a surrounding context line rather than the match itself.
  public var isContext: Bool

  public init(file: String, lineNumber: Int, line: String, isContext: Bool = false) {
    self.file = file
    self.lineNumber = lineNumber
    self.line = line
    self.isContext = isContext
  }
}

/// One page of a ``VirtualFileSystem/grep(...)``.
public struct GrepPage: Sendable, Hashable, Codable {
  /// Matching lines (and their context lines) in walk order.
  public var lines: [GrepLine]
  /// The number of *matches* (not counting context lines) on this page.
  public var matchCount: Int
  /// Whether the match-limit was reached.
  public var matchLimitReached: Bool
  /// Whether the entry-limit was reached before the tree was exhausted.
  public var entryLimitReached: Bool
  /// A continuation cursor, or `nil` when fully scanned.
  public var next: SearchCursor?

  public init(lines: [GrepLine], matchCount: Int, matchLimitReached: Bool, entryLimitReached: Bool, next: SearchCursor?) {
    self.lines = lines
    self.matchCount = matchCount
    self.matchLimitReached = matchLimitReached
    self.entryLimitReached = entryLimitReached
    self.next = next
  }
}

/// Options for a content grep, independent of the path-walk caps.
public struct GrepOptions: Sendable, Hashable {
  /// An optional file glob: only files matching it are searched.
  public var fileGlob: String?
  /// Case-insensitive matching.
  public var ignoreCase: Bool
  /// Treat `pattern` as a literal substring instead of a regex.
  public var literal: Bool
  /// Lines of context to include before and after each match.
  public var contextLines: Int

  public init(fileGlob: String? = nil, ignoreCase: Bool = false, literal: Bool = false, contextLines: Int = 0) {
    self.fileGlob = fileGlob
    self.ignoreCase = ignoreCase
    self.literal = literal
    self.contextLines = contextLines
  }
}

public extension VirtualFileSystem {
  /// Find files under `root` whose path matches the glob `pattern`, honoring
  /// `.gitignore`. Caps results at `matchLimit` and entries scanned at
  /// `entryLimit`; `step` resumes a previous paged search. The default
  /// implementation walks the tree via ``children(of:)``/``status(at:)``; a
  /// remote backend overrides it to answer in one round trip (`WuhuNewSpec.md:344`).
  func find(
    root: VFSPath,
    pattern: String,
    matchLimit: Int,
    entryLimit: Int,
    step: SearchCursor?,
  ) async throws -> FindPage {
    try await VFSSearch.find(in: self, root: root, pattern: pattern, matchLimit: matchLimit, entryLimit: entryLimit, step: step)
  }

  /// Search file contents under `root` for `pattern`, honoring `.gitignore` and
  /// `options.fileGlob`. Caps matches at `matchLimit` and entries scanned at
  /// `entryLimit`; `step` resumes a previous paged search.
  func grep(
    root: VFSPath,
    pattern: String,
    options: GrepOptions,
    matchLimit: Int,
    entryLimit: Int,
    step: SearchCursor?,
  ) async throws -> GrepPage {
    try await VFSSearch.grep(in: self, root: root, pattern: pattern, options: options, matchLimit: matchLimit, entryLimit: entryLimit, step: step)
  }
}
