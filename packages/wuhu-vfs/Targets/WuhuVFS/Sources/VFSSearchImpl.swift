import Foundation

/// The default tree-walk implementations of ``VirtualFileSystem/find(...)`` and
/// ``VirtualFileSystem/grep(...)``.
///
/// Self-contained in `wuhu-vfs`: it walks any `VirtualFileSystem` through the
/// path surface (`children`/`status`/`readData`) applying the relocated
/// ``VFSGlob`` + ``VFSGitignore`` matchers. A node-tree backend (``NodeTreeVFS``)
/// uses this directly; a remote backend overrides `find`/`grep` to answer in one
/// round trip and never reaches here.
///
/// The walk is a deterministic name-sorted depth-first traversal, so paging is
/// reproducible: the cursor is the relative path of the last entry scanned, and
/// a resumed page skips entries up to and including it (best-effort if the tree
/// mutated between pages, `WuhuNewSpec.md:347`).
enum VFSSearch {
  /// Directory names never descended into, mirroring the prior tool behavior.
  static let alwaysSkippedDirectoryNames: Set<String> = [
    ".build", ".git", ".swiftpm", "DerivedData", "node_modules",
  ]

  // MARK: - Find

  static func find(
    in vfs: some VirtualFileSystem,
    root: VFSPath,
    pattern: String,
    matchLimit: Int,
    entryLimit: Int,
    step: SearchCursor?,
  ) async throws -> FindPage {
    try await requireDirectory(vfs, root)
    let matchCap = max(1, matchLimit)
    let entryCap = max(1, entryLimit)
    guard let matcher = try? VFSGlob.compile(pattern: pattern, anchored: true) else {
      return FindPage(paths: [], matchLimitReached: false, entryLimitReached: false, next: nil)
    }

    var paths: [String] = []
    // find emits one result per file, so a per-file "resume after" cursor is
    // lossless — there is no mid-file boundary to straddle.
    var walk = Walk(resume: step.map { .after($0.raw) }, entryCap: entryCap)
    try await walk.run(vfs: vfs, root: root) { entry in
      guard !entry.isDirectory else { return .continue }
      guard matcher.matches(path: entry.relativePath) else { return .continue }
      paths.append(entry.relativePath)
      return paths.count >= matchCap ? .stopMatchLimit : .continue
    }

    return FindPage(
      paths: paths,
      matchLimitReached: walk.stoppedAtMatchLimit,
      entryLimitReached: walk.stoppedAtEntryLimit,
      next: walk.continuation,
    )
  }

  // MARK: - Grep

  static func grep(
    in vfs: some VirtualFileSystem,
    root: VFSPath,
    pattern: String,
    options: GrepOptions,
    matchLimit: Int,
    entryLimit: Int,
    step: SearchCursor?,
  ) async throws -> GrepPage {
    let matchCap = max(1, matchLimit)
    let entryCap = max(1, entryLimit)
    let contextLines = max(0, options.contextLines)

    // A grep root may be a single file (search it directly) or a directory.
    guard let status = try await vfs.status(at: root) else {
      throw VFSError.notFound(path: root.absoluteFilePath)
    }

    let fileMatcher: VFSGlob.Matcher? = options.fileGlob.flatMap { try? VFSGlob.compile(pattern: $0, anchored: true) }
    let regex: NSRegularExpression? = {
      guard !options.literal else { return nil }
      return try? NSRegularExpression(pattern: pattern, options: options.ignoreCase ? [.caseInsensitive] : [])
    }()
    func lineMatches(_ line: String) -> Bool {
      if options.literal {
        return options.ignoreCase ? line.localizedCaseInsensitiveContains(pattern) : line.contains(pattern)
      }
      guard let regex else { return false }
      return regex.firstMatch(in: line, range: NSRange(line.startIndex ..< line.endIndex, in: line)) != nil
    }

    var lines: [GrepLine] = []
    var matchCount = 0

    /// Scan one file from `fromLine` (0-indexed). Each match is fully emitted
    /// (match line + context) before the cap is re-checked, so a file never
    /// becomes a boundary with zero matches emitted.
    ///
    /// Returns `capHit` (the match cap was hit during this file, so the walk must
    /// stop) and `resumeLine` (the 0-indexed line to resume this file from on the
    /// next page, non-nil only when the cap was hit *mid-file* — lines remain).
    /// `resumeLine == nil` with `capHit == true` means the cap landed on the
    /// file's last matching line: stop, but resume from the *next* file.
    func searchFile(at path: VFSPath, relativePath: String, fromLine: Int) async throws -> (capHit: Bool, resumeLine: Int?) {
      let content: String
      do {
        guard let decoded = String(data: try await vfs.readData(at: path), encoding: .utf8) else { return (false, nil) }
        content = decoded
      } catch {
        return (false, nil)
      }
      let normalized = content.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
      let fileLines = normalized.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
      guard fromLine < fileLines.count else { return (false, nil) }
      for index in fromLine ..< fileLines.count {
        guard lineMatches(fileLines[index]) else { continue }
        matchCount += 1
        let lineNumber = index + 1
        let start = max(1, lineNumber - contextLines)
        let end = min(fileLines.count, lineNumber + contextLines)
        for current in start ... end {
          lines.append(GrepLine(file: relativePath, lineNumber: current, line: fileLines[current - 1], isContext: current != lineNumber))
        }
        if matchCount >= matchCap {
          let hasMore = index + 1 < fileLines.count
          return (true, hasMore ? index + 1 : nil)
        }
      }
      return (false, nil)
    }

    if status.kind == .file {
      let resumeLine = (try GrepCursor.decode(step))?.line ?? 0
      let scan = try await searchFile(at: root, relativePath: root.components.last?.rawValue ?? root.absoluteFilePath, fromLine: resumeLine)
      return GrepPage(
        lines: lines,
        matchCount: matchCount,
        matchLimitReached: scan.capHit,
        entryLimitReached: false,
        next: scan.resumeLine.map { GrepCursor(file: "", line: $0).encoded },
      )
    }

    // A grep cursor pins a (file, line) so resume re-visits the boundary file at
    // its saved line offset; a bare cursor (entry-limit pause) carries no line.
    let cursor = try GrepCursor.decode(step)
    var walk = Walk(resume: cursor.map { .at($0.file) } ?? step.map { .after($0.raw) }, entryCap: entryCap)
    var midFileResume: Int? = nil
    try await walk.run(vfs: vfs, root: root) { entry in
      guard !entry.isDirectory else { return .continue }
      if let fileMatcher, !fileMatcher.matches(path: entry.relativePath) { return .continue }
      // Only the boundary file named by the cursor starts mid-file; all others
      // start at line 0.
      let fromLine = (entry.relativePath == cursor?.file) ? (cursor?.line ?? 0) : 0
      let scan = try await searchFile(at: entry.path, relativePath: entry.relativePath, fromLine: fromLine)
      if scan.capHit {
        midFileResume = scan.resumeLine
        return .stopMatchLimit
      }
      return .continue
    }

    // When the cap was hit *mid-file*, override the walk's per-file cursor with a
    // (file, line) cursor so the boundary file's remaining matches survive the
    // page boundary. When the cap was hit on a file's last line (or it was an
    // entry-limit pause), the per-file cursor is correct: resume after the
    // boundary file.
    let next: SearchCursor? = if let midFileResume, let boundary = walk.lastVisited {
      GrepCursor(file: boundary, line: midFileResume).encoded
    } else {
      walk.continuation
    }

    return GrepPage(
      lines: lines,
      matchCount: matchCount,
      matchLimitReached: walk.stoppedAtMatchLimit,
      entryLimitReached: walk.stoppedAtEntryLimit,
      next: next,
    )
  }

  // MARK: - Walk

  private static func requireDirectory(_ vfs: some VirtualFileSystem, _ root: VFSPath) async throws {
    guard let status = try await vfs.status(at: root) else {
      throw VFSError.notFound(path: root.absoluteFilePath)
    }
    guard status.kind == .directory else {
      throw VFSError.notADirectory(path: root.absoluteFilePath)
    }
  }
}

/// A resumable, entry-capped, gitignore-aware depth-first file walk.
private struct Walk {
  enum Disposition { case `continue`, stopMatchLimit }

  /// Where a resumed walk re-enters the deterministic traversal.
  enum Resume {
    /// Skip entries up to *and including* this relative path (find paging, and
    /// grep's between-files entry-limit pause — the boundary entry is done).
    case after(String)
    /// Skip entries up to but *not including* this relative path, so it is
    /// re-visited (grep's mid-file match-limit pause — the boundary file has
    /// unscanned lines and must be re-opened at its saved line offset).
    case at(String)

    /// The anchor relative path.
    var anchor: String {
      switch self {
      case let .after(path), let .at(path): path
      }
    }

    /// Whether the anchor entry itself is re-visited (`.at`) rather than skipped
    /// (`.after`).
    var includesAnchor: Bool {
      switch self {
      case .after: false
      case .at: true
      }
    }
  }

  struct Entry {
    var path: VFSPath
    /// Search-root-relative, `/`-separated path.
    var relativePath: String
    var isDirectory: Bool
  }

  let resume: Resume?
  /// Maximum entries (files + directories) scanned before pausing.
  let entryCap: Int

  private(set) var stoppedAtMatchLimit = false
  private(set) var stoppedAtEntryLimit = false
  /// The relative path of the last entry the visitor ran on — the cursor's raw
  /// for find paging and entry-limit pauses, and the boundary file for a grep
  /// mid-file stop.
  private(set) var lastVisited: String?
  private var scannedCount = 0
  private var reachedResumePoint: Bool

  var continuation: SearchCursor? {
    (stoppedAtMatchLimit || stoppedAtEntryLimit) ? lastVisited.map(SearchCursor.init(raw:)) : nil
  }

  init(resume: Resume?, entryCap: Int) {
    self.resume = resume
    self.entryCap = entryCap
    reachedResumePoint = resume == nil
  }

  mutating func run(
    vfs: some VirtualFileSystem,
    root: VFSPath,
    visit: (Entry) async throws -> Disposition,
  ) async throws {
    _ = try await walk(vfs: vfs, directory: root, relativePrefix: "", inheritedRules: [], visit: visit)
  }

  /// Returns whether the caller should stop the whole walk.
  private mutating func walk(
    vfs: some VirtualFileSystem,
    directory: VFSPath,
    relativePrefix: String,
    inheritedRules: [VFSGitignore.Rule],
    visit: (Entry) async throws -> Disposition,
  ) async throws -> Bool {
    let names = try await vfs.children(of: directory)
      .map(\.name)
      .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }

    var activeRules = inheritedRules
    if names.contains(".gitignore"),
       let component = VFSPathComponent(rawValue: ".gitignore"),
       let data = try? await vfs.readData(at: directory.appending(component)),
       let text = String(data: data, encoding: .utf8)
    {
      activeRules.append(contentsOf: VFSGitignore.parse(text: text, baseDir: relativePrefix))
    }

    // Resume fast-forward: when this directory is on the anchor's ancestor
    // chain, `anchorComponent` is the anchor's name at *this* depth and
    // `anchorIsFinal` says whether that component is the boundary entry itself
    // (vs. an intermediate directory we must descend through). Names sorting
    // strictly before `anchorComponent` were fully scanned on a prior page — we
    // skip them WITHOUT `status()` and WITHOUT descending, which is the whole
    // point of F55: a resumed page re-walks only the O(depth) ancestor chain,
    // never the already-scanned prefix subtrees.
    let fastForward: (component: String, isFinal: Bool, includeAnchor: Bool)? = {
      guard !reachedResumePoint, let resume else { return nil }
      let anchor = resume.anchor
      // The anchor tail relative to this directory.
      let tail: Substring
      if relativePrefix.isEmpty {
        tail = anchor[...]
      } else {
        guard anchor == relativePrefix || anchor.hasPrefix(relativePrefix + "/") else {
          // This directory is not on the anchor chain (it sorts after the
          // anchor's ancestor at the parent level); resume is already complete
          // for it. Should not happen because we only descend ancestors, but be
          // safe and treat as fully resumed.
          return nil
        }
        tail = anchor.dropFirst(relativePrefix.count + 1)
      }
      guard !tail.isEmpty else { return nil }
      if let slash = tail.firstIndex(of: "/") {
        return (String(tail[..<slash]), false, false)
      }
      // Final component: `.after` excludes the anchor, `.at` re-includes it.
      return (String(tail), true, resume.includesAnchor)
    }()

    // If we are resuming but this directory is not on the anchor chain (the
    // anchor IS this directory, or it lies outside), everything here is already
    // past the anchor — resume is complete for this subtree.
    if !reachedResumePoint, resume != nil, fastForward == nil {
      reachedResumePoint = true
    }

    for name in names {
      // Fast-forward skip: drop every name strictly before the anchor's
      // component at this depth without any `status()` round trip.
      if let fastForward, !reachedResumePoint,
         name.localizedCaseInsensitiveCompare(fastForward.component) == .orderedAscending
      {
        continue
      }

      // The anchor's own component at this depth, while still fast-forwarding.
      let atAnchorComponent = !reachedResumePoint && fastForward?.component == name

      guard let component = VFSPathComponent(rawValue: name) else { continue }
      let childPath = directory.appending(component)

      // Intermediate anchor component: descend through the ancestor directory
      // (still fast-forwarding inside) WITHOUT visiting it as an entry and
      // without a `status()` for siblings before it. One `status()` here is the
      // only per-level cost on the resume path.
      if atAnchorComponent, let fastForward, !fastForward.isFinal {
        guard let status = try await vfs.status(at: childPath) else { continue }
        if status.kind == .directory {
          let relativePath = relativePrefix.isEmpty ? name : relativePrefix + "/" + name
          if VFSGitignore.isIgnored(relativePath: relativePath, isDirectory: true, rules: activeRules) { continue }
          if try await walk(vfs: vfs, directory: childPath, relativePrefix: relativePath, inheritedRules: activeRules, visit: visit) {
            return true
          }
        }
        continue
      }

      // Final anchor component or a sibling after it: resume is complete from
      // here on at this level.
      if atAnchorComponent, let fastForward, fastForward.isFinal {
        reachedResumePoint = true
        if !fastForward.includeAnchor {
          // `.after` the anchor: the boundary entry is done. If it is a
          // directory, descend to reach its post-anchor children (now fully
          // resumed); otherwise skip past the leaf.
          guard let status = try await vfs.status(at: childPath) else { continue }
          let relativePath = relativePrefix.isEmpty ? name : relativePrefix + "/" + name
          if status.kind == .directory {
            if VFSGitignore.isIgnored(relativePath: relativePath, isDirectory: true, rules: activeRules) { continue }
            if VFSSearch.alwaysSkippedDirectoryNames.contains(name) { continue }
            if try await walk(vfs: vfs, directory: childPath, relativePrefix: relativePath, inheritedRules: activeRules, visit: visit) {
              return true
            }
          }
          continue
        }
        // `.at` the anchor (grep mid-file): fall through and re-visit it.
      } else if !reachedResumePoint, fastForward != nil {
        // name sorts strictly after the anchor component: a post-anchor sibling.
        reachedResumePoint = true
      }

      guard let status = try await vfs.status(at: childPath) else { continue }
      let isDirectory = status.kind == .directory
      let relativePath = relativePrefix.isEmpty ? name : relativePrefix + "/" + name

      if isDirectory, VFSSearch.alwaysSkippedDirectoryNames.contains(name) { continue }
      if VFSGitignore.isIgnored(relativePath: relativePath, isDirectory: isDirectory, rules: activeRules) { continue }

      // Entry-limit: pause before scanning beyond the cap.
      if scannedCount >= entryCap {
        stoppedAtEntryLimit = true
        return true
      }
      scannedCount += 1
      lastVisited = relativePath

      let disposition = try await visit(Entry(path: childPath, relativePath: relativePath, isDirectory: isDirectory))
      if disposition == .stopMatchLimit {
        stoppedAtMatchLimit = true
        return true
      }

      if isDirectory {
        if try await walk(vfs: vfs, directory: childPath, relativePrefix: relativePath, inheritedRules: activeRules, visit: visit) {
          return true
        }
      }
    }
    return false
  }
}

/// grep's *sub-file* continuation cursor: the boundary file (search-root-relative
/// path) plus the 0-indexed line to resume from within it.
///
/// grep emits per *line* but the walk pages per *file*, so a match-limit hit
/// mid-file would lose the boundary file's remaining matches under a bare
/// per-file cursor. This cursor pins the exact file + line so the next page
/// re-visits that file (the walk's `.at` resume) and grep starts it at `line`,
/// guaranteeing pages union to the full result set. It serializes as JSON inside
/// the opaque ``SearchCursor`` `raw`; a non-JSON `raw` (e.g. an entry-limit pause
/// cursor) decodes to `nil` and is treated as a bare per-file `.after` resume.
struct GrepCursor: Codable {
  var file: String
  var line: Int

  var encoded: SearchCursor {
    // Encoding a two-field struct of String/Int cannot fail; fall back to a bare
    // file cursor rather than crash if it somehow does.
    guard let data = try? JSONEncoder().encode(self), let raw = String(data: data, encoding: .utf8) else {
      return SearchCursor(raw: file)
    }
    return SearchCursor(raw: raw)
  }

  /// Decode a grep cursor from `step`, or `nil` if `step` is absent or not a
  /// grep (file, line) cursor.
  static func decode(_ step: SearchCursor?) throws -> GrepCursor? {
    guard let raw = step?.raw, let data = raw.data(using: .utf8) else { return nil }
    return try? JSONDecoder().decode(GrepCursor.self, from: data)
  }
}
